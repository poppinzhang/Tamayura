#ifndef RUNNER_DESKTOP_TRAY_H_
#define RUNNER_DESKTOP_TRAY_H_

#include <gio/gio.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "tray_icon.h"

namespace tamayura {

// A StatusNotifierItem with a two-entry dbusmenu, exported directly over the
// session bus. KDE Plasma, Ubuntu's default desktop (AppIndicator), Xfce,
// Cinnamon, MATE, Budgie and most Wayland bars host such items. The tray is
// available only while a watcher has accepted the item and reports a host;
// without one, closing the window quits as usual.
class DesktopTray {
 public:
  struct Callbacks {
    // Show and focus the window; the token is an xdg-activation token when
    // the host provided one, otherwise empty.
    std::function<void(const std::string& activation_token)> open;
    std::function<void()> quit;
    std::function<void(bool available)> availability_changed;
  };

  // A null connection leaves the tray unavailable.
  DesktopTray(GDBusConnection* connection, std::vector<TrayIcon> icons,
              Callbacks callbacks);
  ~DesktopTray();
  DesktopTray(const DesktopTray&) = delete;
  DesktopTray& operator=(const DesktopTray&) = delete;

  bool available() const { return registered_ && host_; }
  const std::string& bus_name() const { return bus_name_; }
  // Refreshes the title, tooltip and menu in the current language.
  void LanguageChanged();
  // Refreshes the icon in an already registered tray after a theme change.
  void SetIcons(std::vector<TrayIcon> icons);

  static constexpr int kOpenItem = 1;
  static constexpr int kSeparatorItem = 2;
  static constexpr int kQuitItem = 3;

 private:
  static void OnNameAcquired(GDBusConnection*, const gchar*, gpointer data);
  static void OnNameLost(GDBusConnection*, const gchar*, gpointer data);
  static void OnWatcherAppeared(GDBusConnection*, const gchar*, const gchar* owner,
                                gpointer data);
  static void OnWatcherVanished(GDBusConnection*, const gchar*, gpointer data);
  static void OnRegistered(GObject* source, GAsyncResult* result, gpointer data);
  static void OnHostProperty(GObject* source, GAsyncResult* result, gpointer data);
  static void OnHostSignal(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                           const gchar* signal, GVariant*, gpointer data);
  static void OnItemMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                           const gchar* method, GVariant* parameters,
                           GDBusMethodInvocation* invocation, gpointer data);
  static GVariant* OnItemProperty(GDBusConnection*, const gchar*, const gchar*,
                                  const gchar*, const gchar* property, GError**,
                                  gpointer data);
  static void OnMenuMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                           const gchar* method, GVariant* parameters,
                           GDBusMethodInvocation* invocation, gpointer data);
  static GVariant* OnMenuProperty(GDBusConnection*, const gchar*, const gchar*,
                                  const gchar*, const gchar* property, GError**,
                                  gpointer data);

  void Register();
  void QueryHost();
  void SetState(bool registered, bool host);
  void Event(int id);
  GVariant* ItemProperties(int id) const;
  GVariant* Layout(int id) const;
  GVariant* Pixmaps() const;
  GVariant* ToolTip() const;

  GDBusConnection* connection_ = nullptr;
  GCancellable* cancellable_ = nullptr;
  std::vector<TrayIcon> icons_;
  Callbacks callbacks_;
  std::string bus_name_;
  std::string watcher_owner_;
  std::string activation_token_;
  guint item_registration_ = 0;
  guint menu_registration_ = 0;
  guint name_owner_ = 0;
  guint watcher_watch_ = 0;
  guint host_registered_ = 0;
  guint host_unregistered_ = 0;
  uint32_t revision_ = 1;
  bool registered_ = false;
  bool host_ = false;
};

}  // namespace tamayura

#endif  // RUNNER_DESKTOP_TRAY_H_
