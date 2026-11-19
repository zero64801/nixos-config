// A client of Go's crypto/tls for tests.lab.tlsscan-libraries: connects, writes its secrets where SSLKEYLOGFILE says,
// sends a request and waits for the answer.
package main

import (
	"crypto/tls"
	"fmt"
	"io"
	"os"
)

func main() {
	keys, err := os.Create(os.Getenv("SSLKEYLOGFILE"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	config := &tls.Config{InsecureSkipVerify: true, KeyLogWriter: keys, MinVersion: tls.VersionTLS13}
	if os.Args[2] == "1.2" {
		config.MinVersion, config.MaxVersion = tls.VersionTLS12, tls.VersionTLS12
		config.CipherSuites = []uint16{tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256}
	}
	connection, err := tls.Dial("tcp", os.Args[1], config)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Fprint(connection, "GET / HTTP/1.0\r\n\r\n")
	io.Copy(io.Discard, connection)
}
