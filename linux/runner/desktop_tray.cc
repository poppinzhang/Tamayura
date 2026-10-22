#include "desktop_tray.h"

#include <unistd.h>

#include <utility>

#include "app_text.h"

namespace tamayura {
namespace {

constexpr char kWatcherName[] = "org.kde.StatusNotifierWatcher";
constexpr char kWatcherPath[] = "/StatusNotifierWatcher";
constexpr char kWatcherInterface[] = "org.kde.StatusNotifierWatcher";
constexpr char kItemPath[] = "/StatusNotifierItem";
constexpr char kItemInterface[] = "org.kde.StatusNotifierItem";
constexpr char kMenuPath[] = "/MenuBar";
constexpr char kMenuInterface[] = "com.canonical.dbusmenu";

constexpr char kIntrospection[] = R"XML(<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    <method name="ProvideXdgActivationToken"><arg name="token" type="s" direction="in"/></method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewOverlayIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus"><arg name="status" type="s"/></signal>
  </interface>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg type="i" name="parentId" direction="in"/>
      <arg type="i" name="recursionDepth" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="u" name="revision" direction="out"/>
      <arg type="(ia{sv}av)" name="layout" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="a(ia{sv})" name="properties" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="name" direction="in"/>
      <arg type="v" name="value" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="eventId" direction="in"/>
      <arg type="v" name="data" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg type="a(isvu)" name="events" direction="in"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg type="i" name="id" direction="in"/>
      <arg type="b" name="needUpdate" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="ai" name="updatesNeeded" direction="out"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})" name="updatedProps"/>
      <arg type="a(ias)" name="removedProps"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg type="u" name="revision"/>
      <arg type="i" name="parent"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg type="i" name="id"/>
      <arg type="u" name="timestamp"/>
    </signal>
  </interface>
</node>)XML";

GDBusNodeInfo* Introspection() {
  static GDBusNodeInfo* info = g_dbus_node_info_new_for_xml(kIntrospection, nullptr);
  return info;
}

// dbusmenu treats "_" as a mnemonic prefix.
std::string MenuLabel(TextId id) {
  std::string label;
  for (const char* character = app_text::Text(id); *character; ++character) {
    if (*character == '_') label.push_back('_');
    label.push_back(*character);
  }
  return label;
}

bool Cancelled(const GError* error) {
  return g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
}

GVariant* EmptyPixmaps() { return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr, 0); }

}  // namespace

DesktopTray::DesktopTray(GDBusConnection* connection, std::vector<TrayIcon> icons,
                         Callbacks callbacks)
    : icons_(std::move(icons)), callbacks_(std::move(callbacks)) {
  if (!connection || !Introspection()) return;
  connection_ = G_DBUS_CONNECTION(g_object_ref(connection));
  cancellable_ = g_cancellable_new();
  static const GDBusInterfaceVTable item_vtable = {OnItemMethod, OnItemProperty, nullptr, {}};
  static const GDBusInterfaceVTable menu_vtable = {OnMenuMethod, OnMenuProperty, nullptr, {}};
  item_registration_ = g_dbus_connection_register_object(
      connection_, kItemPath, g_dbus_node_info_lookup_interface(Introspection(), kItemInterface),
      &item_vtable, this, nullptr, nullptr);
  menu_registration_ = g_dbus_connection_register_object(
      connection_, kMenuPath, g_dbus_node_info_lookup_interface(Introspection(), kMenuInterface),
      &menu_vtable, this, nullptr, nullptr);
  if (!item_registration_ || !menu_registration_) return;
  bus_name_ = "org.kde.StatusNotifierItem-" + std::to_string(getpid()) + "-1";
  name_owner_ = g_bus_own_name_on_connection(connection_, bus_name_.c_str(),
                                             G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE, OnNameAcquired,
                                             OnNameLost, this, nullptr);
}

DesktopTray::~DesktopTray() {
  // Pending replies complete as cancelled and never touch this object.
  if (cancellable_) {
    g_cancellable_cancel(cancellable_);
    g_object_unref(cancellable_);
  }
  if (host_registered_) g_dbus_connection_signal_unsubscribe(connection_, host_registered_);
  if (host_unregistered_) g_dbus_connection_signal_unsubscribe(connection_, host_unregistered_);
  if (watcher_watch_) g_bus_unwatch_name(watcher_watch_);
  if (name_owner_) g_bus_unown_name(name_owner_);
  if (item_registration_) g_dbus_connection_unregister_object(connection_, item_registration_);
  if (menu_registration_) g_dbus_connection_unregister_object(connection_, menu_registration_);
  if (connection_) g_object_unref(connection_);
}

void DesktopTray::OnNameAcquired(GDBusConnection*, const gchar*, gpointer data) {
  auto* self = static_cast<DesktopTray*>(data);
  if (self->watcher_watch_) return;
  self->watcher_watch_ = g_bus_watch_name_on_connection(
      self->connection_, kWatcherName, G_BUS_NAME_WATCHER_FLAGS_NONE, OnWatcherAppeared,
      OnWatcherVanished, self, nullptr);
}

void DesktopTray::OnNameLost(GDBusConnection*, const gchar*, gpointer data) {
  static_cast<DesktopTray*>(data)->SetState(false, false);
}

void DesktopTray::OnWatcherAppeared(GDBusConnection*, const gchar*, const gchar* owner,
                                    gpointer data) {
  auto* self = static_cast<DesktopTray*>(data);
  self->watcher_owner_ = owner;
  if (!self->host_registered_) {
    self->host_registered_ = g_dbus_connection_signal_subscribe(
        self->connection_, owner, kWatcherInterface, "StatusNotifierHostRegistered",
        kWatcherPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, OnHostSignal, self, nullptr);
    self->host_unregistered_ = g_dbus_connection_signal_subscribe(
        self->connection_, owner, kWatcherInterface, "StatusNotifierHostUnregistered",
        kWatcherPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, OnHostSignal, self, nullptr);
  }
  self->Register();
}

void DesktopTray::OnWatcherVanished(GDBusConnection*, const gchar*, gpointer data) {
  auto* self = static_cast<DesktopTray*>(data);
  self->watcher_owner_.clear();
  if (self->host_registered_) {
    g_dbus_connection_signal_unsubscribe(self->connection_, self->host_registered_);
    g_dbus_connection_signal_unsubscribe(self->connection_, self->host_unregistered_);
    self->host_registered_ = self->host_unregistered_ = 0;
  }
  self->SetState(false, false);
}

void DesktopTray::Register() {
  g_dbus_connection_call(connection_, watcher_owner_.c_str(), kWatcherPath, kWatcherInterface,
                         "RegisterStatusNotifierItem", g_variant_new("(s)", bus_name_.c_str()),
                         nullptr, G_DBUS_CALL_FLAGS_NONE, 5000, cancellable_, OnRegistered,
                         this);
}

void DesktopTray::OnRegistered(GObject* source, GAsyncResult* result, gpointer data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (Cancelled(error)) return;
  auto* self = static_cast<DesktopTray*>(data);
  if (!reply) {
    self->SetState(false, false);
    return;
  }
  self->registered_ = true;
  self->QueryHost();
}

void DesktopTray::QueryHost() {
  if (watcher_owner_.empty()) return;
  g_dbus_connection_call(connection_, watcher_owner_.c_str(), kWatcherPath,
                         "org.freedesktop.DBus.Properties", "Get",
                         g_variant_new("(ss)", kWatcherInterface, "IsStatusNotifierHostRegistered"),
                         G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 5000, cancellable_,
                         OnHostProperty, this);
}

void DesktopTray::OnHostProperty(GObject* source, GAsyncResult* result, gpointer data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (Cancelled(error)) return;
  auto* self = static_cast<DesktopTray*>(data);
  bool host = false;
  if (reply) {
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(reply, "(v)", &value);
    host = g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) && g_variant_get_boolean(value);
  }
  self->SetState(self->registered_, host);
}

void DesktopTray::OnHostSignal(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                               const gchar* signal, GVariant*, gpointer data) {
  auto* self = static_cast<DesktopTray*>(data);
  if (g_strcmp0(signal, "StatusNotifierHostRegistered") == 0) {
    self->SetState(self->registered_, true);
  } else {
    // Other hosts may remain.
    self->QueryHost();
  }
}

void DesktopTray::SetState(bool registered, bool host) {
  const bool was = available();
  registered_ = registered;
  host_ = host;
  if (was != available() && callbacks_.availability_changed) {
    callbacks_.availability_changed(available());
  }
}

void DesktopTray::Event(int id) {
  if (id == kOpenItem && callbacks_.open) {
    callbacks_.open(std::exchange(activation_token_, std::string()));
  } else if (id == kQuitItem && callbacks_.quit) {
    callbacks_.quit();
  }
}

GVariant* DesktopTray::Pixmaps() const {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a(iiay)"));
  for (const auto& icon : icons_) {
    g_variant_builder_add(&builder, "(ii@ay)", icon.width, icon.height,
                          g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, icon.argb.data(),
                                                    icon.argb.size(), 1));
  }
  return g_variant_builder_end(&builder);
}

GVariant* DesktopTray::ToolTip() const {
  return g_variant_new("(s@a(iiay)ss)", "", EmptyPixmaps(), app_text::Text(TextId::kAppName),
                       app_text::Text(TextId::kTrayTooltip));
}

GVariant* DesktopTray::OnItemProperty(GDBusConnection*, const gchar*, const gchar*,
                                      const gchar*, const gchar* property, GError** error,
                                      gpointer data) {
  auto* self = static_cast<DesktopTray*>(data);
  const std::string name(property);
  if (name == "Category") return g_variant_new_string("ApplicationStatus");
  if (name == "Id") return g_variant_new_string("tamayura");
  if (name == "Title") return g_variant_new_string(app_text::Text(TextId::kAppName));
  if (name == "Status") return g_variant_new_string("Active");
  if (name == "WindowId") return g_variant_new_int32(0);
  if (name == "IconPixmap") return self->Pixmaps();
  if (name == "OverlayIconPixmap" || name == "AttentionIconPixmap") return EmptyPixmaps();
  if (name == "IconName" || name == "OverlayIconName" || name == "AttentionIconName" ||
      name == "AttentionMovieName") {
    return g_variant_new_string("");
  }
  if (name == "ToolTip") return self->ToolTip();
  if (name == "ItemIsMenu") return g_variant_new_boolean(FALSE);
  if (name == "Menu") return g_variant_new_object_path(kMenuPath);
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown property %s", property);
  return nullptr;
}

void DesktopTray::OnItemMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                               const gchar* method, GVariant* parameters,
                               GDBusMethodInvocation* invocation, gpointer data) {
  auto* self = static_cast<DesktopTray*>(data);
  const std::string name(method);
  if (name == "ProvideXdgActivationToken") {
    const gchar* token = nullptr;
    g_variant_get(parameters, "(&s)", &token);
    self->activation_token_ = token ? token : "";
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }
  g_dbus_method_invocation_return_value(invocation, nullptr);
  // Hosts that cannot show the dbusmenu ask for a context menu; opening the
  // window keeps the app reachable, and Ctrl+Q still quits it.
  if (name == "Activate" || name == "SecondaryActivate" || name == "ContextMenu") {
    self->Event(kOpenItem);
  }
}

GVariant* DesktopTray::ItemProperties(int id) const {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
  if (id == 0) {
    g_variant_builder_add(&builder, "{sv}", "children-display", g_variant_new_string("submenu"));
  } else if (id == kSeparatorItem) {
    g_variant_builder_add(&builder, "{sv}", "type", g_variant_new_string("separator"));
    g_variant_builder_add(&builder, "{sv}", "visible", g_variant_new_boolean(TRUE));
  } else if (id == kOpenItem || id == kQuitItem) {
    const auto label = MenuLabel(id == kOpenItem ? TextId::kOpenApp : TextId::kQuitApp);
    g_variant_builder_add(&builder, "{sv}", "label", g_variant_new_string(label.c_str()));
    g_variant_builder_add(&builder, "{sv}", "enabled", g_variant_new_boolean(TRUE));
    g_variant_builder_add(&builder, "{sv}", "visible", g_variant_new_boolean(TRUE));
  }
  return g_variant_builder_end(&builder);
}

GVariant* DesktopTray::Layout(int id) const {
  GVariantBuilder children;
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
  if (id == 0) {
    for (const int child : {kOpenItem, kSeparatorItem, kQuitItem}) {
      g_variant_builder_add(&children, "v", Layout(child));
    }
  }
  return g_variant_new("(i@a{sv}@av)", id, ItemProperties(id), g_variant_builder_end(&children));
}

GVariant* DesktopTray::OnMenuProperty(GDBusConnection*, const gchar*, const gchar*,
                                      const gchar*, const gchar* property, GError** error,
                                      gpointer) {
  const std::string name(property);
  if (name == "Version") return g_variant_new_uint32(3);
  if (name == "TextDirection") return g_variant_new_string("ltr");
  if (name == "Status") return g_variant_new_string("normal");
  if (name == "IconThemePath") return g_variant_new_strv(nullptr, 0);
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown property %s", property);
  return nullptr;
}

void DesktopTray::OnMenuMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                               const gchar* method, GVariant* parameters,
                               GDBusMethodInvocation* invocation, gpointer data) {
  auto* self = static_cast<DesktopTray*>(data);
  const std::string name(method);
  const auto known = [](int id) { return id >= 0 && id <= kQuitItem; };
  if (name == "GetLayout") {
    gint32 parent = 0, depth = 0;
    g_autoptr(GVariant) names = nullptr;
    g_variant_get(parameters, "(ii@as)", &parent, &depth, &names);
    if (!known(parent)) {
      g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
                                            "Unknown menu item %d", parent);
      return;
    }
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(u@(ia{sv}av))", self->revision_, self->Layout(parent)));
  } else if (name == "GetGroupProperties") {
    g_autoptr(GVariant) ids = nullptr;
    g_autoptr(GVariant) names = nullptr;
    g_variant_get(parameters, "(@ai@as)", &ids, &names);
    std::vector<gint32> requested;
    gsize count = 0;
    const auto* values = static_cast<const gint32*>(
        g_variant_get_fixed_array(ids, &count, sizeof(gint32)));
    requested.assign(values, values + count);
    if (requested.empty()) requested = {0, kOpenItem, kSeparatorItem, kQuitItem};
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a(ia{sv})"));
    for (const auto id : requested) {
      if (known(id)) g_variant_builder_add(&builder, "(i@a{sv})", id, self->ItemProperties(id));
    }
    g_dbus_method_invocation_return_value(invocation,
                                          g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&builder)));
  } else if (name == "GetProperty") {
    gint32 id = 0;
    const gchar* key = nullptr;
    g_variant_get(parameters, "(i&s)", &id, &key);
    g_autoptr(GVariant) properties = known(id) ? self->ItemProperties(id) : nullptr;
    if (properties) g_variant_ref_sink(properties);
    g_autoptr(GVariant) value =
        properties ? g_variant_lookup_value(properties, key, nullptr) : nullptr;
    if (!value) {
      g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
                                            "Unknown menu property");
      return;
    }
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value));
  } else if (name == "Event") {
    gint32 id = 0;
    const gchar* event = nullptr;
    g_autoptr(GVariant) payload = nullptr;
    guint32 timestamp = 0;
    g_variant_get(parameters, "(i&svu)", &id, &event, &payload, &timestamp);
    g_dbus_method_invocation_return_value(invocation, nullptr);
    if (g_strcmp0(event, "clicked") == 0) self->Event(id);
  } else if (name == "EventGroup") {
    g_autoptr(GVariantIter) events = nullptr;
    g_variant_get(parameters, "(a(isvu))", &events);
    std::vector<gint32> clicked;
    gint32 id = 0;
    const gchar* event = nullptr;
    GVariant* payload = nullptr;
    guint32 timestamp = 0;
    while (g_variant_iter_loop(events, "(i&svu)", &id, &event, &payload, &timestamp)) {
      if (g_strcmp0(event, "clicked") == 0) clicked.push_back(id);
    }
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0)));
    for (const auto item : clicked) self->Event(item);
  } else if (name == "AboutToShow") {
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
  } else if (name == "AboutToShowGroup") {
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(@ai@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0),
                                  g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0)));
  } else {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                          "Unknown method %s", method);
  }
}

void DesktopTray::LanguageChanged() {
  if (!connection_) return;
  ++revision_;
  g_dbus_connection_emit_signal(connection_, nullptr, kMenuPath, kMenuInterface, "LayoutUpdated",
                                g_variant_new("(ui)", revision_, 0), nullptr);
  g_dbus_connection_emit_signal(connection_, nullptr, kItemPath, kItemInterface, "NewTitle",
                                nullptr, nullptr);
  g_dbus_connection_emit_signal(connection_, nullptr, kItemPath, kItemInterface, "NewToolTip",
                                nullptr, nullptr);
}

}  // namespace tamayura
