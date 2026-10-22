#ifndef TAMAYURA_LINUX_PLATFORM_H_
#define TAMAYURA_LINUX_PLATFORM_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <functional>
#include <memory>
#include <string>

#include "main_dispatcher.h"
#include "media_preview.h"
#include "settings_store.h"
#include "storage_core.h"

namespace tamayura {
class LanDiscovery;
struct DiscoveryEvent;

// The tamayura/platform, tamayura/updates, tamayura/discovery and
// tamayura/sharing channels. Arguments are read on the GTK main thread;
// storage work runs on a worker pool and replies are built back on the main
// thread, where FlValue and the messenger may be used.
class LinuxPlatform {
 public:
  struct Host {
    // The main window, which may be hidden.
    std::function<GtkWindow*()> window;
    // The interface language changed; refresh native window and tray text.
    std::function<void()> language_changed;
  };

  LinuxPlatform(FlBinaryMessenger* messenger, Host host);
  ~LinuxPlatform();
  LinuxPlatform(const LinuxPlatform&) = delete;
  LinuxPlatform& operator=(const LinuxPlatform&) = delete;

 private:
  // Builds the reply value on the main thread; null replies with null.
  using Reply = std::function<FlValue*()>;

  static void OnMethodCall(FlMethodChannel* channel, FlMethodCall* call, gpointer data);
  static void OnUpdateCall(FlMethodChannel* channel, FlMethodCall* call, gpointer data);
  static FlMethodErrorResponse* OnDiscoveryListen(FlEventChannel*, FlValue*, gpointer data);
  static FlMethodErrorResponse* OnDiscoveryCancel(FlEventChannel*, FlValue*, gpointer data);
  static FlMethodErrorResponse* OnSharingListen(FlEventChannel*, FlValue*, gpointer data);
  static FlMethodErrorResponse* OnSharingCancel(FlEventChannel*, FlValue*, gpointer data);
  static void OnPickerResponse(GtkNativeDialog* dialog, gint response, gpointer data);

  void Handle(FlMethodCall* call);
  void HandleUpdate(FlMethodCall* call);
  void Background(FlMethodCall* call, std::function<Reply()> operation);
  void PickDirectory(FlMethodCall* call);
  struct RevealRequest;
  static void CompleteReveal(RevealRequest* request, bool shown);
  void Launch(FlMethodCall* call, const std::string& uri, bool reveal);
  void Reveal(FlMethodCall* call, const std::string& path);
  bool ShowUri(const std::string& uri);
  FlValue* SharingStatus() const;
  void SendDiscovery(const DiscoveryEvent& event);

  Host host_;
  std::shared_ptr<MainDispatcher> dispatcher_;
  std::shared_ptr<MediaCatalog> catalog_;
  std::shared_ptr<const PreviewOptions> preview_options_;
  SettingsStore settings_;
  std::unique_ptr<LanDiscovery> discovery_;
  // Outlives asynchronous GDBus replies that may arrive after destruction.
  std::shared_ptr<LinuxPlatform*> self_;
  FlMethodChannel* methods_ = nullptr;
  FlMethodChannel* updates_ = nullptr;
  FlEventChannel* discovery_events_ = nullptr;
  FlEventChannel* sharing_events_ = nullptr;
  bool discovery_listening_ = false;
  bool sharing_listening_ = false;
  bool sharing_enabled_ = false;
  GtkFileChooserNative* picker_ = nullptr;
  FlMethodCall* picker_call_ = nullptr;
  // Declared last: joined first, before the members its tasks use.
  WorkerPool workers_;
};

}  // namespace tamayura

#endif  // TAMAYURA_LINUX_PLATFORM_H_
