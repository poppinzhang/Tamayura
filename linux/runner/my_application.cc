#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <string>
#include <vector>

#include "app_text.h"
#include "desktop_tray.h"
#include "flutter/generated_plugin_registrant.h"
#include "linux_platform.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The one main window. Closing it to the tray only hides it, keeping the
  // Flutter engine, page state and downloads alive.
  GtkWindow* window;
  GtkHeaderBar* header_bar;
  tamayura::LinuxPlatform* platform;
  tamayura::DesktopTray* tray;
  gboolean quitting;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

namespace {

constexpr int kIconSizes[] = {16, 22, 24, 32, 48, 64, 128, 256, 512};

// Icons are installed next to the executable, in a hicolor theme layout.
std::string IconPath(int size) {
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (!executable) return {};
  g_autofree gchar* directory = g_path_get_dirname(executable);
  const auto folder = std::to_string(size) + "x" + std::to_string(size);
  g_autofree gchar* path = g_build_filename(directory, "data", "icons", "hicolor", folder.c_str(),
                                            "apps", APPLICATION_ID ".png", nullptr);
  return path;
}

GList* WindowIcons() {
  GList* icons = nullptr;
  for (const int size : kIconSizes) {
    if (size > 256) continue;
    if (GdkPixbuf* icon = gdk_pixbuf_new_from_file(IconPath(size).c_str(), nullptr)) {
      icons = g_list_append(icons, icon);
    }
  }
  return icons;
}

std::vector<tamayura::TrayIcon> TrayIcons() {
  std::vector<tamayura::TrayIcon> icons;
  for (const int size : kIconSizes) {
    if (size > 64) continue;
    g_autoptr(GdkPixbuf) loaded = gdk_pixbuf_new_from_file(IconPath(size).c_str(), nullptr);
    if (!loaded) continue;
    g_autoptr(GdkPixbuf) image = gdk_pixbuf_add_alpha(loaded, FALSE, 0, 0, 0);
    if (!image) continue;
    tamayura::TrayIcon icon;
    icon.width = gdk_pixbuf_get_width(image);
    icon.height = gdk_pixbuf_get_height(image);
    const int stride = gdk_pixbuf_get_rowstride(image);
    const guchar* pixels = gdk_pixbuf_get_pixels(image);
    icon.argb.reserve(static_cast<size_t>(icon.width) * icon.height * 4);
    for (int y = 0; y < icon.height; ++y) {
      for (int x = 0; x < icon.width; ++x) {
        const guchar* pixel = pixels + y * stride + x * 4;
        // RGBA to ARGB32 in network byte order.
        icon.argb.insert(icon.argb.end(), {pixel[3], pixel[0], pixel[1], pixel[2]});
      }
    }
    icons.push_back(std::move(icon));
  }
  return icons;
}

void UpdateTitle(MyApplication* self) {
  const char* title = tamayura::app_text::Text(tamayura::TextId::kAppName);
  if (self->header_bar) gtk_header_bar_set_title(self->header_bar, title);
  if (self->window) gtk_window_set_title(self->window, title);
}

void PresentWindow(MyApplication* self, const std::string& activation_token) {
  if (!self->window) return;
  if (!activation_token.empty()) {
    // Lets a Wayland compositor focus the window on behalf of the tray.
    gtk_window_set_startup_id(self->window, activation_token.c_str());
  }
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_deiconify(self->window);
  guint32 timestamp = GDK_CURRENT_TIME;
#ifdef GDK_WINDOWING_X11
  GdkWindow* native = gtk_widget_get_window(GTK_WIDGET(self->window));
  // A real server time avoids X11 focus-stealing prevention.
  if (native && GDK_IS_X11_WINDOW(native)) timestamp = gdk_x11_get_server_time(native);
#endif
  gtk_window_present_with_time(self->window, timestamp);
}

// Quitting goes through the same close request as a window without a tray,
// so Flutter's exit handling still runs.
void RequestQuit(MyApplication* self) {
  self->quitting = TRUE;
  if (self->window && gtk_widget_get_realized(GTK_WIDGET(self->window))) {
    gtk_window_close(self->window);
  } else {
    g_application_quit(G_APPLICATION(self));
  }
}

// Connected before Flutter's own handler, which asks Dart whether to exit.
gboolean WindowDeleteEvent(GtkWidget* widget, GdkEvent*, MyApplication* self) {
  if (!self->quitting && self->tray && self->tray->available()) {
    gtk_widget_hide(widget);
    return TRUE;
  }
  return FALSE;
}

void QuitAction(GSimpleAction*, GVariant*, gpointer data) {
  RequestQuit(MY_APPLICATION(data));
}

void FirstFrame(MyApplication* self, FlView*) {
  if (self->window) gtk_widget_show(GTK_WIDGET(self->window));
}

}  // namespace

// Implements GApplication::activate. A later launch of the app activates the
// running instance, which reopens a window hidden in the tray.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window) {
    PresentWindow(self, "");
    return;
  }
  GtkWindow* window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    self->header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(self->header_bar));
    gtk_header_bar_set_show_close_button(self->header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(self->header_bar));
  }
  UpdateTitle(self);
  gtk_window_set_default_size(window, 1280, 720);
  if (GList* icons = WindowIcons()) {
    gtk_window_set_icon_list(window, icons);
    g_list_free_full(icons, g_object_unref);
  }
  // Must precede the Flutter view's realization; see WindowDeleteEvent.
  g_signal_connect(window, "delete-event", G_CALLBACK(WindowDeleteEvent), self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(FirstFrame), self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view), "TamayuraPlatform");
  self->platform = new tamayura::LinuxPlatform(
      fl_plugin_registrar_get_messenger(registrar),
      {[self] { return self->window; },
       [self] {
         UpdateTitle(self);
         if (self->tray) self->tray->LanguageChanged();
       }});
  self->tray = new tamayura::DesktopTray(
      g_application_get_dbus_connection(application), TrayIcons(),
      {[self](const std::string& token) { PresentWindow(self, token); },
       [self] { RequestQuit(self); },
       [self](bool available) {
         // Never leave a hidden window without a way back.
         if (!available && !self->quitting && self->window &&
             !gtk_widget_get_visible(GTK_WIDGET(self->window))) {
           PresentWindow(self, "");
         }
       }});

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // In a second launch this activates the running instance instead.
  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  static const GActionEntry actions[] = {{"quit", QuitAction, nullptr, nullptr, nullptr, {}}};
  g_action_map_add_action_entries(G_ACTION_MAP(application), actions, G_N_ELEMENTS(actions),
                                  application);
  // Ctrl+Q quits explicitly, also on desktops without a status tray.
  const gchar* quit_accels[] = {"<Primary>q", nullptr};
  gtk_application_set_accels_for_action(GTK_APPLICATION(application), "app.quit", quit_accels);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  delete self->tray;
  self->tray = nullptr;
  delete self->platform;
  self->platform = nullptr;
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication*) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // One instance per user session: two would share the database, the device
  // identity and the service port. Debug builds stay separate so that
  // `flutter run` works next to an installed release.
#ifdef NDEBUG
  const GApplicationFlags flags = G_APPLICATION_DEFAULT_FLAGS;
#else
  const GApplicationFlags flags = G_APPLICATION_NON_UNIQUE;
#endif
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
