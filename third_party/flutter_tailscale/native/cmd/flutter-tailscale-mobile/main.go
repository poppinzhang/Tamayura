//go:build cgo

package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"github.com/flutter-tailscale/flutter-tailscale/native/bridge"
	"io"
	"log"
	"unsafe"
)

var runtime = bridge.New()

func init() { log.SetOutput(io.Discard) }

// ft_request allocates one UTF-8 response. The caller must ft_free it exactly
// once. Control calls must run off the platform/UI thread. Never pass payloads.
//
//export ft_request
func ft_request(request *C.char) *C.char {
	if request == nil {
		return C.CString(`{"id":null,"error":{"code":"invalidRequest","message":"invalidRequest"}}`)
	}
	// Bounded scanning avoids copying an unbounded native request into Go.
	view := unsafe.Slice((*byte)(unsafe.Pointer(request)), bridge.MaxControlBytes+1)
	n := 0
	for n < len(view) && view[n] != 0 {
		n++
	}
	if n > bridge.MaxControlBytes {
		return C.CString(`{"id":null,"error":{"code":"invalidRequest","message":"invalidRequest"}}`)
	}
	return C.CString(string(runtime.Handle(view[:n])))
}

//export ft_free
func ft_free(response *C.char) { C.free(unsafe.Pointer(response)) }
func main()                    {}
