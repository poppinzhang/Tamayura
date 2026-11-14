// The desktop helper accepts bounded newline-delimited JSON over inherited
// pipes only. EOF closes the embedded node and every outstanding connection.
package main

import (
	"bufio"
	"io"
	"log"
	"os"

	"github.com/flutter-tailscale/flutter-tailscale/native/bridge"
)

func main() {
	log.SetOutput(io.Discard)
	r := bridge.New()
	defer r.Close()
	input := bufio.NewScanner(os.Stdin)
	input.Buffer(make([]byte, 4096), bridge.MaxControlBytes)
	output := bufio.NewWriter(os.Stdout)
	for input.Scan() {
		response := r.Handle(input.Bytes())
		if _, err := output.Write(response); err != nil {
			return
		}
		if err := output.WriteByte('\n'); err != nil {
			return
		}
		if output.Flush() != nil {
			return
		}
	}
}
