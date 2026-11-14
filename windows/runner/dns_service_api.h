#ifndef TAMAYURA_DNS_SERVICE_API_H_
#define TAMAYURA_DNS_SERVICE_API_H_

#include <winsock2.h>
#include <windows.h>
#include <windns.h>

#include <functional>

namespace tamayura {
// Injectable OS boundary. Native tests can deliver callbacks concurrently with
// cancellation without depending on a LAN, a DNS service, or a Flutter engine.
struct DnsServiceApi {
  std::function<DWORD(PDNS_SERVICE_REGISTER_REQUEST, PDNS_SERVICE_CANCEL)>
      register_service = DnsServiceRegister;
  std::function<DWORD(PDNS_SERVICE_REGISTER_REQUEST, PDNS_SERVICE_CANCEL)>
      deregister_service = DnsServiceDeRegister;
  std::function<DWORD(PDNS_SERVICE_CANCEL)> cancel_registration = DnsServiceRegisterCancel;
  std::function<DWORD(PDNS_SERVICE_BROWSE_REQUEST, PDNS_SERVICE_CANCEL)>
      browse = DnsServiceBrowse;
  std::function<DWORD(PDNS_SERVICE_CANCEL)> cancel_browse = DnsServiceBrowseCancel;
  std::function<DWORD(PDNS_SERVICE_RESOLVE_REQUEST, PDNS_SERVICE_CANCEL)>
      resolve = DnsServiceResolve;
  std::function<DWORD(PDNS_SERVICE_CANCEL)> cancel_resolve = DnsServiceResolveCancel;
};
}  // namespace tamayura
#endif
