package bridge

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"net"
	"time"
)

func token() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// The session certificate is an in-memory credential of one runtime session.
// Both ends pin its exact bytes, and it is replaced whenever the session
// rotates, so its validity period adds no protection. A short period would
// instead stop a long-running node from delivering inbound streams to its own
// host, and a wall-clock correction could do the same at any time. The bounds
// are therefore fixed and independent of the clock; the upper one is the
// RFC 5280 value for a certificate without a well-defined expiration.
var (
	sessionNotBefore = time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
	sessionNotAfter  = time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
)

func certificate() (tls.Certificate, string, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, "", "", err
	}
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "Flutter Tailscale local session"},
		NotBefore: sessionNotBefore, NotAfter: sessionNotAfter,
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		IsCA:        true, BasicConstraintsValid: true,
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", "", err
	}
	priv, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return tls.Certificate{}, "", "", err
	}
	certPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: priv}))
	pair, err := tls.X509KeyPair([]byte(certPEM), []byte(keyPEM))
	return pair, certPEM, keyPEM, err
}
