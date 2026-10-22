#include "desktop_tray.h"

#include <gio/gio.h>

#include <chrono>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "app_text.h"

namespace {
using namespace tamayura;

void Expect(bool value, const std::string& message) {
  if (!value) throw std::runtime_error(message);
}

// Iterates the default main context, where the tray and the fake watcher
// dispatch their D-Bus traffic, until `ready` or a timeout.
bool Wait(const std::function<bool()>& ready, int milliseconds = 5000) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
  while (!ready()) {
    if (std::chrono::steady_clock::now() > deadline) return false;
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(1000);
  }
  return true;
}

// An asynchronous call, so the tray in this process can answer it.
GVariant* Call(GDBusConnection* connection, const std::string& destination, const char* path,
               const char* interface, const char* method, GVariant* parameters,
               GError** failure = nullptr) {
  struct Result {
    bool done = false;
    GVariant* value = nullptr;
    GError* error = nullptr;
  } result;
  g_dbus_connection_call(
      connection, destination.c_str(), path, interface, method, parameters, nullptr,
      G_DBUS_CALL_FLAGS_NONE, 5000, nullptr,
      [](GObject* source, GAsyncResult* async, gpointer data) {
        auto* result = static_cast<Result*>(data);
        result->value = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), async, &result->error);
        result->done = true;
      },
      &result);
  Expect(Wait([&] { return result.done; }), std::string("No reply to ") + method);
  if (failure) {
    *failure = result.error;
  } else if (result.error) {
    const std::string message = result.error->message;
    g_error_free(result.error);
    throw std::runtime_error(std::string(method) + " failed: " + message);
  }
  return result.value;
}

GVariant* Property(GDBusConnection* connection, const std::string& destination, const char* path,
                   const char* interface, const char* name) {
  GVariant* reply = Call(connection, destination, path, "org.freedesktop.DBus.Properties", "Get",
                         g_variant_new("(ss)", interface, name));
  GVariant* value = nullptr;
  g_variant_get(reply, "(v)", &value);
  g_variant_unref(reply);
  return value;
}

constexpr char kWatcherXml[] = R"XML(<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg name="service" type="s" direction="in"/></method>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <signal name="StatusNotifierHostRegistered"/>
    <signal name="StatusNotifierHostUnregistered"/>
  </interface>
</node>)XML";

// A minimal StatusNotifierWatcher with a host, as KDE Plasma or the
// AppIndicator extension provide, on its own bus connection.
class FakeWatcher {
 public:
  FakeWatcher(const std::string& address, bool host) : host_(host) {
    connection_ = g_dbus_connection_new_for_address_sync(
        address.c_str(),
        static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                                          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, nullptr);
    Expect(connection_ != nullptr, "watcher connection");
    info_ = g_dbus_node_info_new_for_xml(kWatcherXml, nullptr);
    static const GDBusInterfaceVTable vtable = {OnMethod, OnProperty, nullptr, {}};
    registration_ = g_dbus_connection_register_object(connection_, "/StatusNotifierWatcher",
                                                      info_->interfaces[0], &vtable, this,
                                                      nullptr, nullptr);
    owner_ = g_bus_own_name_on_connection(connection_, "org.kde.StatusNotifierWatcher",
                                          G_BUS_NAME_OWNER_FLAGS_NONE,
                                          [](GDBusConnection*, const gchar*, gpointer data) {
                                            static_cast<FakeWatcher*>(data)->owned_ = true;
                                          },
                                          nullptr, this, nullptr);
    Expect(Wait([this] { return owned_; }), "watcher name owned");
  }
  ~FakeWatcher() {
    g_bus_unown_name(owner_);
    g_dbus_connection_unregister_object(connection_, registration_);
    g_dbus_connection_close_sync(connection_, nullptr, nullptr);
    g_object_unref(connection_);
    g_dbus_node_info_unref(info_);
  }
  void SetHost(bool host) {
    host_ = host;
    g_dbus_connection_emit_signal(connection_, nullptr, "/StatusNotifierWatcher",
                                  "org.kde.StatusNotifierWatcher",
                                  host ? "StatusNotifierHostRegistered"
                                       : "StatusNotifierHostUnregistered",
                                  nullptr, nullptr);
  }
  GDBusConnection* connection() const { return connection_; }
  std::vector<std::string> registered;

 private:
  static void OnMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*,
                       GVariant* parameters, GDBusMethodInvocation* invocation, gpointer data) {
    const gchar* service = nullptr;
    g_variant_get(parameters, "(&s)", &service);
    static_cast<FakeWatcher*>(data)->registered.emplace_back(service);
    g_dbus_method_invocation_return_value(invocation, nullptr);
  }
  static GVariant* OnProperty(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                              const gchar*, GError**, gpointer data) {
    return g_variant_new_boolean(static_cast<FakeWatcher*>(data)->host_);
  }
  GDBusConnection* connection_ = nullptr;
  GDBusNodeInfo* info_ = nullptr;
  guint registration_ = 0;
  guint owner_ = 0;
  bool owned_ = false;
  bool host_;
};

std::vector<std::string> Labels(GDBusConnection* connection, const std::string& tray) {
  GVariant* reply = Call(connection, tray, "/MenuBar", "com.canonical.dbusmenu", "GetLayout",
                         g_variant_new("(ii@as)", 0, -1, g_variant_new_strv(nullptr, 0)));
  guint32 revision = 0;
  GVariant* layout = nullptr;
  g_variant_get(reply, "(u@(ia{sv}av))", &revision, &layout);
  gint32 id = 0;
  GVariant* properties = nullptr;
  GVariant* children = nullptr;
  g_variant_get(layout, "(i@a{sv}@av)", &id, &properties, &children);
  std::vector<std::string> labels;
  GVariantIter iterator;
  g_variant_iter_init(&iterator, children);
  GVariant* child = nullptr;
  while (g_variant_iter_next(&iterator, "v", &child)) {
    GVariant* child_properties = nullptr;
    gint32 child_id = 0;
    GVariant* grandchildren = nullptr;
    g_variant_get(child, "(i@a{sv}@av)", &child_id, &child_properties, &grandchildren);
    const gchar* label = nullptr;
    const gchar* type = nullptr;
    if (g_variant_lookup(child_properties, "label", "&s", &label)) {
      labels.emplace_back(std::to_string(child_id) + ":" + label);
    } else if (g_variant_lookup(child_properties, "type", "&s", &type)) {
      labels.emplace_back(std::to_string(child_id) + ":" + type);
    }
    g_variant_unref(child_properties);
    g_variant_unref(grandchildren);
    g_variant_unref(child);
  }
  g_variant_unref(properties);
  g_variant_unref(children);
  g_variant_unref(layout);
  g_variant_unref(reply);
  return labels;
}

struct Events {
  std::vector<std::string> opened;
  int quits = 0;
  std::vector<bool> availability;
};

int Run() {
  g_autofree gchar* daemon = g_find_program_in_path("dbus-daemon");
  if (!daemon) {
    std::cout << "dbus-daemon is not installed; skipping tray tests\n";
    return 77;
  }
  GTestDBus* bus = g_test_dbus_new(G_TEST_DBUS_NONE);
  g_test_dbus_up(bus);
  const std::string address = g_test_dbus_get_bus_address(bus);
  GDBusConnection* session = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  Expect(session != nullptr, "session bus");
  app_text::SetPreference("en");

  Events events;
  auto tray = std::make_unique<DesktopTray>(
      session, std::vector<TrayIcon>{{2, 1, std::vector<uint8_t>(8, 255)}},
      DesktopTray::Callbacks{
          [&](const std::string& token) { events.opened.push_back(token); },
          [&] { ++events.quits; },
          [&](bool available) { events.availability.push_back(available); }});
  // Without a watcher the tray is unavailable and closing the window quits.
  Wait([] { return false; }, 300);
  Expect(!tray->available() && events.availability.empty(), "no watcher, no tray");

  auto watcher = std::make_unique<FakeWatcher>(address, true);
  Expect(Wait([&] { return tray->available(); }), "registered with a hosted watcher");
  Expect(events.availability == std::vector<bool>{true}, "availability reported once");
  Expect(watcher->registered == std::vector<std::string>{tray->bus_name()},
         "registered by its well-known name");
  GDBusConnection* host = watcher->connection();
  const auto name = tray->bus_name();

  GVariant* title = Property(host, name, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "Title");
  Expect(g_strcmp0(g_variant_get_string(title, nullptr), "Tamayura") == 0, "item title");
  g_variant_unref(title);
  GVariant* menu = Property(host, name, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "Menu");
  Expect(g_strcmp0(g_variant_get_string(menu, nullptr), "/MenuBar") == 0, "menu path");
  g_variant_unref(menu);
  GVariant* pixmaps =
      Property(host, name, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "IconPixmap");
  Expect(g_variant_n_children(pixmaps) == 1, "icon pixmaps");
  gint32 width = 0, height = 0;
  GVariant* bytes = nullptr;
  g_variant_get_child(pixmaps, 0, "(ii@ay)", &width, &height, &bytes);
  Expect(width == 2 && height == 1 && g_variant_n_children(bytes) == 8, "ARGB pixmap size");
  g_variant_unref(bytes);
  g_variant_unref(pixmaps);
  GVariant* tooltip =
      Property(host, name, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "ToolTip");
  const gchar* tooltip_title = nullptr;
  const gchar* tooltip_text = nullptr;
  g_variant_get(tooltip, "(&s@a(iiay)&s&s)", nullptr, nullptr, &tooltip_title, &tooltip_text);
  Expect(g_strcmp0(tooltip_text, app_text::Text(TextId::kTrayTooltip)) == 0, "tooltip text");
  g_variant_unref(tooltip);

  g_variant_unref(Call(host, name, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "Activate",
                       g_variant_new("(ii)", 0, 0)));
  Expect(Wait([&] { return events.opened.size() == 1; }) && events.opened[0].empty(),
         "activation opens the window");
  g_variant_unref(Call(host, name, "/StatusNotifierItem", "org.kde.StatusNotifierItem",
                       "ProvideXdgActivationToken", g_variant_new("(s)", "token-1")));
  g_variant_unref(Call(host, name, "/StatusNotifierItem", "org.kde.StatusNotifierItem",
                       "SecondaryActivate", g_variant_new("(ii)", 0, 0)));
  Expect(Wait([&] { return events.opened.size() == 2; }) && events.opened[1] == "token-1",
         "activation token is passed on once");

  Expect(Labels(host, name) ==
             std::vector<std::string>{"1:Open Tamayura", "2:separator", "3:Quit Tamayura"},
         "menu layout");
  g_variant_unref(Call(host, name, "/MenuBar", "com.canonical.dbusmenu", "Event",
                       g_variant_new("(isvu)", DesktopTray::kQuitItem, "clicked",
                                     g_variant_new_int32(0), 0)));
  Expect(Wait([&] { return events.quits == 1; }), "Quit item quits");
  g_variant_unref(Call(host, name, "/MenuBar", "com.canonical.dbusmenu", "Event",
                       g_variant_new("(isvu)", DesktopTray::kQuitItem, "hovered",
                                     g_variant_new_int32(0), 0)));
  GVariantBuilder group;
  g_variant_builder_init(&group, G_VARIANT_TYPE("a(isvu)"));
  g_variant_builder_add(&group, "(isvu)", DesktopTray::kOpenItem, "clicked",
                        g_variant_new_int32(0), 0u);
  g_variant_builder_add(&group, "(isvu)", DesktopTray::kSeparatorItem, "clicked",
                        g_variant_new_int32(0), 0u);
  g_variant_unref(Call(host, name, "/MenuBar", "com.canonical.dbusmenu", "EventGroup",
                       g_variant_new("(@a(isvu))", g_variant_builder_end(&group))));
  Expect(Wait([&] { return events.opened.size() == 3; }) && events.quits == 1,
         "only clicks on items act");
  GError* error = nullptr;
  GVariant* missing = Call(host, name, "/MenuBar", "com.canonical.dbusmenu", "GetLayout",
                           g_variant_new("(ii@as)", 9, -1, g_variant_new_strv(nullptr, 0)), &error);
  Expect(!missing && error, "unknown menu items are rejected");
  g_error_free(error);

  // Language changes refresh the hosted menu.
  guint revisions = 0;
  const guint subscription = g_dbus_connection_signal_subscribe(
      host, nullptr, "com.canonical.dbusmenu", "LayoutUpdated", "/MenuBar", nullptr,
      G_DBUS_SIGNAL_FLAGS_NONE,
      [](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant*,
         gpointer data) { ++*static_cast<guint*>(data); },
      &revisions, nullptr);
  app_text::SetPreference("zh");
  tray->LanguageChanged();
  Expect(Wait([&] { return revisions == 1; }), "layout update signalled");
  Expect(Labels(host, name) ==
             std::vector<std::string>{"1:打开玉响", "2:separator", "3:退出玉响"},
         "translated menu");
  g_dbus_connection_signal_unsubscribe(host, subscription);

  // The host leaves while the watcher stays, then returns.
  watcher->SetHost(false);
  Expect(Wait([&] { return !tray->available(); }), "unavailable without a host");
  watcher->SetHost(true);
  Expect(Wait([&] { return tray->available(); }), "available when a host returns");

  // The watcher itself restarts.
  watcher.reset();
  Expect(Wait([&] { return !tray->available(); }), "unavailable without a watcher");
  watcher = std::make_unique<FakeWatcher>(address, false);
  Expect(Wait([&] { return watcher->registered.size() == 1; }), "registers with a new watcher");
  Wait([] { return false; }, 200);
  Expect(!tray->available(), "a watcher without a host is not a usable tray");
  watcher->SetHost(true);
  Expect(Wait([&] { return tray->available(); }), "available once a host registers");
  Expect(events.availability == std::vector<bool>{true, false, true, false, true},
         "every change reported once");

  // Destroying the tray releases its name; pending replies are ignored.
  tray.reset();
  GVariant* owner = Call(watcher->connection(), "org.freedesktop.DBus", "/org/freedesktop/DBus",
                         "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", name.c_str()));
  gboolean has_owner = TRUE;
  g_variant_get(owner, "(b)", &has_owner);
  g_variant_unref(owner);
  Expect(!has_owner, "item name released");

  watcher.reset();
  g_object_unref(session);
  g_test_dbus_down(bus);
  g_object_unref(bus);
  std::cout << "Linux tray tests passed\n";
  return 0;
}

}  // namespace

int main() {
  try {
    return Run();
  } catch (const std::exception& error) {
    std::cerr << "[FAIL] tray: " << error.what() << '\n';
    return 1;
  }
}
