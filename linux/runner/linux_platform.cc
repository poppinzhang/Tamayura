#include "linux_platform.h"

#include <regex>
#include <set>
#include <utility>

#include "app_text.h"
#include "discovery_core.h"
#include "lan_discovery.h"

namespace tamayura {
namespace {

// Arguments are copied out of FlValue on the main thread.
FlValue* Argument(FlValue* arguments, const char* key) {
  if (!arguments || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) return nullptr;
  return fl_value_lookup_string(arguments, key);
}

[[noreturn]] void Missing(const char* key) {
  throw StorageError("INVALID_ARGUMENT", app_text::Format(TextId::kMissingArgument, key));
}

std::string String(FlValue* arguments, const char* key) {
  FlValue* value = Argument(arguments, key);
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_STRING ||
      !*fl_value_get_string(value)) {
    Missing(key);
  }
  return fl_value_get_string(value);
}

int64_t Integer(FlValue* arguments, const char* key) {
  FlValue* value = Argument(arguments, key);
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_INT) Missing(key);
  return fl_value_get_int(value);
}

std::vector<std::string> Strings(FlValue* arguments, const char* key) {
  FlValue* value = Argument(arguments, key);
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_LIST) Missing(key);
  std::vector<std::string> result;
  for (size_t index = 0; index < fl_value_get_length(value); ++index) {
    FlValue* item = fl_value_get_list_value(value, index);
    if (fl_value_get_type(item) != FL_VALUE_TYPE_STRING) Missing(key);
    result.emplace_back(fl_value_get_string(item));
  }
  return result;
}

std::vector<SharedDirectory> Directories(FlValue* arguments) {
  FlValue* value = Argument(arguments, "directories");
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_LIST) Missing("directories");
  std::vector<SharedDirectory> result;
  for (size_t index = 0; index < fl_value_get_length(value); ++index) {
    FlValue* folder = fl_value_get_list_value(value, index);
    if (fl_value_get_type(folder) != FL_VALUE_TYPE_MAP) Missing("directories");
    result.push_back({String(folder, "id"), String(folder, "uri"), String(folder, "name")});
  }
  return result;
}

void RespondSuccess(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlValue) owned = value;
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(call, owned, &error)) {
    g_warning("Cannot answer %s: %s", fl_method_call_get_name(call), error->message);
  }
}

void RespondError(FlMethodCall* call, const std::string& code, const std::string& message) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_error(call, code.c_str(), message.c_str(), nullptr, &error)) {
    g_warning("Cannot answer %s: %s", fl_method_call_get_name(call), error->message);
  }
}

FlValue* ByteList(const tamayura::Bytes& bytes) {
  return fl_value_new_uint8_list(bytes.data(), bytes.size());
}

FlValue* StringList(const std::vector<std::string>& values) {
  FlValue* list = fl_value_new_list();
  for (const auto& value : values) fl_value_append_take(list, fl_value_new_string(value.c_str()));
  return list;
}

FlValue* Metadata(const MediaEntry& entry) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "id", fl_value_new_string(entry.id.c_str()));
  fl_value_set_string_take(map, "name", fl_value_new_string(entry.name.c_str()));
  fl_value_set_string_take(map, "mimeType", fl_value_new_string(entry.mime_type.c_str()));
  fl_value_set_string_take(map, "size", fl_value_new_int(entry.size));
  fl_value_set_string_take(map, "modifiedMs", fl_value_new_int(entry.modified_ms));
  fl_value_set_string_take(map, "sharedFolderId", fl_value_new_string(entry.shared_folder_id.c_str()));
  fl_value_set_string_take(map, "sharedFolderName",
                           fl_value_new_string(entry.shared_folder_name.c_str()));
  fl_value_set_string_take(map, "relativePath", fl_value_new_string(entry.relative_path.c_str()));
  return map;
}

// The file must still be a supported, ordinary local file when handed to
// another application.
std::string LaunchablePath(const std::string& uri) {
  const auto path = LocalPath(uri);
  if (MediaMime(BaseName(path)).empty()) {
    throw StorageError("INVALID_ARGUMENT", TextId::kUnsupportedMedia);
  }
  return SafeFile::Open(path).path();
}

}  // namespace

LinuxPlatform::LinuxPlatform(FlBinaryMessenger* messenger, Host host)
    : host_(std::move(host)),
      dispatcher_(std::make_shared<MainDispatcher>()),
      catalog_(std::make_shared<MediaCatalog>()),
      preview_options_(std::make_shared<PreviewOptions>(PreviewOptions::ForSharedMedia())),
      settings_(SettingsStore::DefaultDirectory()),
      self_(std::make_shared<LinuxPlatform*>(this)) {
  // Load gdk-pixbuf's module list before workers decode concurrently.
  g_slist_free(gdk_pixbuf_get_formats());
  sharing_enabled_ = settings_.BackgroundSharing();
  discovery_ = std::make_unique<LanDiscovery>(
      dispatcher_, [this](const DiscoveryEvent& event) { SendDiscovery(event); });
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  methods_ = fl_method_channel_new(messenger, "tamayura/platform", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(methods_, OnMethodCall, this, nullptr);
  updates_ = fl_method_channel_new(messenger, "tamayura/updates", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(updates_, OnUpdateCall, this, nullptr);
  discovery_events_ = fl_event_channel_new(messenger, "tamayura/discovery", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(discovery_events_, OnDiscoveryListen, OnDiscoveryCancel,
                                       this, nullptr);
  sharing_events_ = fl_event_channel_new(messenger, "tamayura/sharing", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(sharing_events_, OnSharingListen, OnSharingCancel, this,
                                       nullptr);
}

LinuxPlatform::~LinuxPlatform() {
  self_.reset();
  fl_method_channel_set_method_call_handler(methods_, nullptr, nullptr, nullptr);
  fl_method_channel_set_method_call_handler(updates_, nullptr, nullptr, nullptr);
  fl_event_channel_set_stream_handlers(discovery_events_, nullptr, nullptr, nullptr, nullptr);
  fl_event_channel_set_stream_handlers(sharing_events_, nullptr, nullptr, nullptr, nullptr);
  discovery_->Stop();
  // Cancel running scans and thumbnailers before joining the workers.
  catalog_->Clear();
  CancelThumbnailers();
  dispatcher_->Shutdown();
  workers_.Stop();
  if (picker_) {
    gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(picker_));
    g_object_unref(picker_);
  }
  if (picker_call_) g_object_unref(picker_call_);
  g_object_unref(methods_);
  g_object_unref(updates_);
  g_object_unref(discovery_events_);
  g_object_unref(sharing_events_);
}

void LinuxPlatform::OnMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* self = static_cast<LinuxPlatform*>(data);
  try {
    self->Handle(call);
  } catch (const StorageError& error) {
    RespondError(call, error.code, error.what());
  } catch (const std::exception&) {
    RespondError(call, "PLATFORM_ERROR", app_text::Text(TextId::kOperationFailed));
  }
}

void LinuxPlatform::OnUpdateCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* self = static_cast<LinuxPlatform*>(data);
  try {
    self->HandleUpdate(call);
  } catch (const StorageError& error) {
    RespondError(call, error.code, error.what());
  }
}

FlMethodErrorResponse* LinuxPlatform::OnDiscoveryListen(FlEventChannel*, FlValue*, gpointer data) {
  auto* self = static_cast<LinuxPlatform*>(data);
  self->discovery_listening_ = true;
  self->discovery_->Replay();
  return nullptr;
}

FlMethodErrorResponse* LinuxPlatform::OnDiscoveryCancel(FlEventChannel*, FlValue*, gpointer data) {
  static_cast<LinuxPlatform*>(data)->discovery_listening_ = false;
  return nullptr;
}

FlMethodErrorResponse* LinuxPlatform::OnSharingListen(FlEventChannel*, FlValue*, gpointer data) {
  auto* self = static_cast<LinuxPlatform*>(data);
  self->sharing_listening_ = true;
  // Deliver the current state after the listen call has been answered.
  std::weak_ptr<LinuxPlatform*> owner = self->self_;
  self->dispatcher_->Post([owner] {
    const auto alive = owner.lock();
    if (!alive || !(*alive)->sharing_listening_) return;
    g_autoptr(FlValue) status = (*alive)->SharingStatus();
    fl_event_channel_send((*alive)->sharing_events_, status, nullptr, nullptr);
  });
  return nullptr;
}

FlMethodErrorResponse* LinuxPlatform::OnSharingCancel(FlEventChannel*, FlValue*, gpointer data) {
  static_cast<LinuxPlatform*>(data)->sharing_listening_ = false;
  return nullptr;
}

FlValue* LinuxPlatform::SharingStatus() const {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "enabled", fl_value_new_bool(sharing_enabled_));
  fl_value_set_string_take(map, "running", fl_value_new_bool(sharing_enabled_));
  fl_value_set_string_take(map, "batteryExempt", fl_value_new_bool(true));
  return map;
}

void LinuxPlatform::SendDiscovery(const DiscoveryEvent& event) {
  if (!discovery_listening_) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "type", fl_value_new_string(event.type.c_str()));
  if (event.type == "error") {
    fl_value_set_string_take(map, "stage", fl_value_new_string(event.stage.c_str()));
    fl_value_set_string_take(map, "code", fl_value_new_int(event.code));
    fl_value_set_string_take(map, "message", fl_value_new_string(event.message.c_str()));
  } else {
    fl_value_set_string_take(map, "id", fl_value_new_string(event.id.c_str()));
    fl_value_set_string_take(map, "name", fl_value_new_string(event.name.c_str()));
    fl_value_set_string_take(map, "host", fl_value_new_string(event.host.c_str()));
    fl_value_set_string_take(map, "port", fl_value_new_int(event.port));
  }
  fl_event_channel_send(discovery_events_, map, nullptr, nullptr);
}

void LinuxPlatform::Background(FlMethodCall* call, std::function<Reply()> operation) {
  g_object_ref(call);
  const auto dispatcher = dispatcher_;
  workers_.Submit([dispatcher, call, operation = std::move(operation)] {
    Reply reply;
    std::string code;
    std::string message;
    try {
      reply = operation();
    } catch (const StorageError& error) {
      code = error.code;
      message = error.what();
    } catch (const std::bad_alloc&) {
      code = "RESOURCE_EXHAUSTED";
      message = app_text::Text(TextId::kResourcesExhausted);
    } catch (...) {
      code = "PLATFORM_ERROR";
      message = app_text::Text(TextId::kOperationFailed);
    }
    dispatcher->Post([call, reply = std::move(reply), code, message] {
      if (code.empty()) {
        RespondSuccess(call, reply ? reply() : nullptr);
      } else {
        RespondError(call, code, message);
      }
      g_object_unref(call);
    });
  });
}

void LinuxPlatform::Handle(FlMethodCall* call) {
  const std::string method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (method == "deviceId") {
    RespondSuccess(call, fl_value_new_string(settings_.DeviceId().c_str()));
  } else if (method == "localInfo") {
    Background(call, [] {
      auto local = LanDiscovery::Local();
      return Reply([local] {
        FlValue* map = fl_value_new_map();
        fl_value_set_string_take(map, "name", fl_value_new_string(local.name.c_str()));
        fl_value_set_string_take(map, "addresses", StringList(local.addresses));
        return map;
      });
    });
  } else if (method == "sharingStatus") {
    RespondSuccess(call, SharingStatus());
  } else if (method == "setBackgroundSharing") {
    FlValue* enabled = Argument(args, "enabled");
    if (!enabled || fl_value_get_type(enabled) != FL_VALUE_TYPE_BOOL) {
      throw StorageError("INVALID_ARGUMENT", TextId::kMissingSharingState);
    }
    settings_.SetBackgroundSharing(fl_value_get_bool(enabled));
    sharing_enabled_ = fl_value_get_bool(enabled);
    if (sharing_listening_) {
      g_autoptr(FlValue) status = SharingStatus();
      fl_event_channel_send(sharing_events_, status, nullptr, nullptr);
    }
    RespondSuccess(call, SharingStatus());
  } else if (method == "startDiscovery") {
    const auto port = Integer(args, "port");
    if (port < 1 || port > 65535) throw StorageError("INVALID_ARGUMENT", TextId::kInvalidPort);
    discovery_->Start(String(args, "id"), String(args, "name"), static_cast<uint16_t>(port));
    RespondSuccess(call, nullptr);
  } else if (method == "stopDiscovery") {
    discovery_->Stop();
    RespondSuccess(call, nullptr);
  } else if (method == "setLanguage") {
    if (!app_text::SetPreference(String(args, "language"))) {
      throw StorageError("INVALID_ARGUMENT", TextId::kInvalidLanguage);
    }
    if (host_.language_changed) host_.language_changed();
    RespondSuccess(call, nullptr);
  } else if (method == "setTransferActivity" || method == "openBatteryOptimizationSettings" ||
             method == "scheduleTransfer" || method == "cancelTransfer") {
    // Downloads are owned by this process; there is no system scheduler.
    RespondSuccess(call, nullptr);
  } else if (method == "scheduledTransferIds") {
    RespondSuccess(call, fl_value_new_list());
  } else if (method == "pickDirectory") {
    PickDirectory(call);
  } else if (method == "validateSharedDirectory") {
    const auto uri = String(args, "uri");
    const auto existing = Strings(args, "existingUris");
    const auto catalog = catalog_;
    Background(call, [catalog, uri, existing] {
      catalog->Validate(uri, existing);
      return Reply();
    });
  } else if (method == "scanDirectoriesMetadata") {
    const auto directories = Directories(args);
    std::set<std::string> ids;
    for (const auto& directory : directories) ids.insert(directory.id);
    // Cancel older scans and drop removed folders now; retained files keep
    // serving peers until this scan publishes its replacement.
    const auto ticket = catalog_->BeginScan(ids);
    const auto catalog = catalog_;
    Background(call, [catalog, directories, ticket] {
      auto entries = catalog->Scan(directories, ticket);
      return Reply([entries = std::move(entries)] {
        FlValue* list = fl_value_new_list();
        for (const auto& entry : entries) fl_value_append_take(list, Metadata(entry));
        return list;
      });
    });
  } else if (method == "clearSharedDirectory") {
    catalog_->Clear();
    RespondSuccess(call, nullptr);
  } else if (method == "thumbnail") {
    const auto id = String(args, "id");
    const auto catalog = catalog_;
    const auto options = preview_options_;
    Background(call, [catalog, options, id] {
      auto bytes = catalog->Thumbnail(id, [&](const MediaEntry& entry, const SafeFile& file) {
        return JpegPreview(file, 256, entry.mime_type, *options);
      });
      return Reply([bytes = std::move(bytes)] { return ByteList(bytes); });
    });
  } else if (method == "readPreview") {
    const auto uri = String(args, "uri");
    const auto maximum = Integer(args, "maxDimension");
    if (maximum < 1 || maximum > 2560) throw StorageError("INVALID_ARGUMENT", TextId::kPreviewRange);
    Background(call, [uri, maximum] {
      const auto path = LocalPath(uri);
      const auto mime = MediaMime(BaseName(path));
      if (mime.empty()) throw StorageError("INVALID_ARGUMENT", TextId::kUnsupportedMedia);
      // Received files are decoded in process only.
      auto bytes = JpegPreview(SafeFile::Open(path), static_cast<unsigned>(maximum), mime,
                               PreviewOptions());
      return Reply([bytes = std::move(bytes)] { return ByteList(bytes); });
    });
  } else if (method == "readRange") {
    const auto id = String(args, "id");
    const auto offset = Integer(args, "offset");
    const auto length = Integer(args, "length");
    const auto catalog = catalog_;
    Background(call, [catalog, id, offset, length] {
      auto bytes = catalog->Read(id, offset, length);
      return Reply([bytes = std::move(bytes)] { return ByteList(bytes); });
    });
  } else if (method == "saveDownload") {
    const auto sources = Strings(args, "sourcePaths");
    const auto expected = Integer(args, "expectedSize");
    const auto destination = String(args, "directoryUri");
    const auto directories = Strings(args, "directories");
    const auto name = String(args, "name");
    Background(call, [sources, expected, destination, directories, name] {
      const auto saved = SaveDownload(
          sources, expected,
          {PrivateDirectory(PrivateArea::kCache), PrivateDirectory(PrivateArea::kTransfers)},
          destination, directories, name);
      return Reply([saved] { return fl_value_new_string(saved.c_str()); });
    });
  } else if (method == "deleteDownload") {
    const auto uri = String(args, "uri");
    Background(call, [uri] {
      DeleteDownload(uri);
      return Reply();
    });
  } else if (method == "transferSpace") {
    const auto destination = String(args, "directoryUri");
    Background(call, [destination] {
      const auto space = TransferSpace(PrivateDirectory(PrivateArea::kTransfers), destination);
      return Reply([space] {
        FlValue* map = fl_value_new_map();
        if (space.staging_available_bytes) {
          fl_value_set_string_take(map, "stagingAvailableBytes",
                                   fl_value_new_int(*space.staging_available_bytes));
        }
        if (space.destination_available_bytes) {
          fl_value_set_string_take(map, "destinationAvailableBytes",
                                   fl_value_new_int(*space.destination_available_bytes));
        }
        if (space.same_volume) {
          fl_value_set_string_take(map, "sameVolume", fl_value_new_bool(*space.same_volume));
        }
        return map;
      });
    });
  } else if (method == "temporaryDirectory" || method == "transferDirectory" ||
             method == "databaseDirectory") {
    const auto area = method == "temporaryDirectory"  ? PrivateArea::kCache
                      : method == "transferDirectory" ? PrivateArea::kTransfers
                                                      : PrivateArea::kDatabases;
    Background(call, [area] {
      const auto path = PrivateDirectory(area);
      return Reply([path] { return fl_value_new_string(path.c_str()); });
    });
  } else if (method == "open" || method == "share") {
    Launch(call, String(args, "uri"), method == "share");
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

void LinuxPlatform::HandleUpdate(FlMethodCall* call) {
  const std::string method = fl_method_call_get_name(call);
  if (method != "openRelease") {
    // Linux updates are installed manually from the release page.
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* value = Argument(fl_method_call_get_args(call), "url");
  static const std::regex release(
      R"(^https://github\.com/poppinzhang/Tamayura/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+$)");
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_STRING ||
      !std::regex_match(fl_value_get_string(value), release)) {
    throw StorageError("INVALID_UPDATE_URL", TextId::kInvalidReleaseUrl);
  }
  if (!ShowUri(fl_value_get_string(value))) {
    throw StorageError("OPEN_RELEASE_FAILED", TextId::kOpenReleaseFailed);
  }
  RespondSuccess(call, nullptr);
}

bool LinuxPlatform::ShowUri(const std::string& uri) {
  // gtk_show_uri_on_window() with a parent window reports success before it
  // knows whether any application handles the URI. Launch through GIO, which
  // reports a missing handler, with GDK's context for startup notification.
  GtkWindow* window = host_.window ? host_.window() : nullptr;
  GdkDisplay* display =
      window ? gtk_widget_get_display(GTK_WIDGET(window)) : gdk_display_get_default();
  if (!display) return false;
  g_autoptr(GdkAppLaunchContext) context = gdk_display_get_app_launch_context(display);
  gdk_app_launch_context_set_timestamp(context, GDK_CURRENT_TIME);
  g_autoptr(GError) error = nullptr;
  return g_app_info_launch_default_for_uri(uri.c_str(), G_APP_LAUNCH_CONTEXT(context), &error);
}

void LinuxPlatform::PickDirectory(FlMethodCall* call) {
  if (picker_) throw StorageError("INVALID_ARGUMENT", TextId::kPickerOpen);
  GtkWindow* window = host_.window ? host_.window() : nullptr;
  if (!window || !gtk_widget_get_visible(GTK_WIDGET(window))) {
    throw StorageError("INVALID_ARGUMENT", TextId::kOpenWindowFirst);
  }
  picker_ = gtk_file_chooser_native_new(app_text::Text(TextId::kChooseFolder), window,
                                        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
                                        app_text::Text(TextId::kChooseAccept),
                                        app_text::Text(TextId::kChooseCancel));
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(picker_), TRUE);
  gtk_file_chooser_set_local_only(GTK_FILE_CHOOSER(picker_), TRUE);
  gtk_file_chooser_set_create_folders(GTK_FILE_CHOOSER(picker_), TRUE);
  picker_call_ = FL_METHOD_CALL(g_object_ref(call));
  g_signal_connect(picker_, "response", G_CALLBACK(OnPickerResponse), this);
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(picker_));
}

void LinuxPlatform::OnPickerResponse(GtkNativeDialog* dialog, gint response, gpointer data) {
  auto* self = static_cast<LinuxPlatform*>(data);
  FlMethodCall* call = std::exchange(self->picker_call_, nullptr);
  gchar* filename =
      response == GTK_RESPONSE_ACCEPT ? gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog))
                                      : nullptr;
  g_clear_object(&self->picker_);
  if (!call) {
    g_free(filename);
    return;
  }
  if (response != GTK_RESPONSE_ACCEPT) {
    RespondSuccess(call, nullptr);
  } else if (!filename) {
    // A location that only exists in a remote GVfs backend has no path.
    RespondError(call, "INVALID_ARGUMENT", app_text::Text(TextId::kSelectLocalFolder));
  } else {
    const std::string path(filename);
    self->Background(call, [path] {
      const auto canonical = ValidateDirectory(path);
      const auto name = canonical == "/" ? std::string("/") : BaseName(canonical);
      return Reply([canonical, name] {
        FlValue* map = fl_value_new_map();
        fl_value_set_string_take(map, "uri", fl_value_new_string(canonical.c_str()));
        fl_value_set_string_take(map, "name", fl_value_new_string(name.c_str()));
        return map;
      });
    });
  }
  g_free(filename);
  g_object_unref(call);
}

void LinuxPlatform::Launch(FlMethodCall* call, const std::string& uri, bool reveal) {
  std::weak_ptr<LinuxPlatform*> owner = self_;
  g_object_ref(call);
  const auto dispatcher = dispatcher_;
  workers_.Submit([owner, dispatcher, call, uri, reveal] {
    std::string path;
    std::string code;
    std::string message;
    try {
      path = LaunchablePath(uri);
    } catch (const StorageError& error) {
      code = error.code;
      message = error.what();
    }
    dispatcher->Post([owner, call, path, code, message, reveal] {
      const auto alive = owner.lock();
      if (!alive) {
        g_object_unref(call);
        return;
      }
      if (!code.empty()) {
        RespondError(call, code, message);
      } else if (reveal) {
        (*alive)->Reveal(call, path);
      } else {
        g_autofree gchar* file_uri = g_filename_to_uri(path.c_str(), nullptr, nullptr);
        if (file_uri && (*alive)->ShowUri(file_uri)) {
          RespondSuccess(call, nullptr);
        } else {
          RespondError(call, "OPEN_FAILED", app_text::Text(TextId::kOpenFailed));
        }
      }
      g_object_unref(call);
    });
  });
}

struct LinuxPlatform::RevealRequest {
  std::weak_ptr<LinuxPlatform*> owner;
  FlMethodCall* call;
  std::string path;
};

void LinuxPlatform::CompleteReveal(RevealRequest* request, bool shown) {
  if (const auto alive = request->owner.lock()) {
    if (!shown) {
      // File managers without org.freedesktop.FileManager1 open the folder.
      g_autofree gchar* folder =
          g_filename_to_uri(ParentPath(request->path).c_str(), nullptr, nullptr);
      shown = folder && (*alive)->ShowUri(folder);
    }
    if (shown) {
      RespondSuccess(request->call, nullptr);
    } else {
      RespondError(request->call, "REVEAL_FAILED", app_text::Text(TextId::kRevealFailed));
    }
  }
  g_object_unref(request->call);
  delete request;
}

void LinuxPlatform::Reveal(FlMethodCall* call, const std::string& path) {
  auto* request = new RevealRequest{self_, FL_METHOD_CALL(g_object_ref(call)), path};
  g_autofree gchar* uri = g_filename_to_uri(path.c_str(), nullptr, nullptr);
  g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (!bus || !uri) {
    CompleteReveal(request, false);
    return;
  }
  const gchar* items[] = {uri, nullptr};
  g_dbus_connection_call(
      bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
      "org.freedesktop.FileManager1", "ShowItems", g_variant_new("(^ass)", items, ""), nullptr,
      G_DBUS_CALL_FLAGS_NONE, 5000, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer data) {
        g_autoptr(GVariant) reply =
            g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, nullptr);
        CompleteReveal(static_cast<RevealRequest*>(data), reply != nullptr);
      },
      request);
}

}  // namespace tamayura
