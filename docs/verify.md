# Verifying a package

Each release publishes `podman_<version>_<arch>.deb` and `podman_<version>_<arch>.deb.sig`, an Ed25519 signature made with the Glyndor release key, plus a `components.txt` that lists the upstream versions it was built from. The public key is in [`keyring/glyndor-release-ed25519.b64`](../keyring/glyndor-release-ed25519.b64).

`apt` verifies the archive signature automatically, so this is only needed when downloading a package by hand. There are two independent checks.

## Check the signature with OpenSSL

You need OpenSSL 3 and `curl`. The key file holds one raw 32-byte Ed25519 public key per line, in base64: one line today, two while a key is being replaced. The steps take the first line; during a replacement a package is good when either key verifies it, so repeat them with the second line if the first refuses. OpenSSL reads a PEM key, so the steps below wrap the raw key in the standard 12-byte DER header (`302a300506032b6570032100`, which is `MCowBQYDK2VwAyEA` in base64). Set `version` and `arch` to the release you downloaded, for example `6.2.0+r8` and `amd64`:

```bash
version='6.2.0+r8'; arch=amd64
deb="podman_${version}_${arch}.deb"

# the key from this repository, as a PEM file
key="$(curl -sSf https://raw.githubusercontent.com/Glyndor/podman/main/keyring/glyndor-release-ed25519.b64 | grep -v '^#' | head -n 1)"
{ echo '-----BEGIN PUBLIC KEY-----'
  printf 'MCowBQYDK2VwAyEA%s=\n' "$key"
  echo '-----END PUBLIC KEY-----'; } > glyndor-release.pem

# the release assets; a literal + in a tag is %2B in the URL
base="https://github.com/Glyndor/podman/releases/download/v${version/+/%2B}"
curl -sSfLO "$base/$deb" -O "$base/$deb.sig"

openssl pkeyutl -verify -pubin -inkey glyndor-release.pem -rawin -in "$deb" -sigfile "$deb.sig"
```

A good package prints `Signature Verified Successfully` and exits with status 0. A package that was changed by even one byte prints `Signature Verification Failure` and exits with status 1; do not install it.

The key is read from this repository, so this proves the package was signed by whoever holds the private key that matches it. To pin the key independently of GitHub, copy the file once and compare it against a copy you obtained from another channel.

## The second signature, when a release has one

Releases do not carry it yet. When they do, each package has a third file, `podman_<version>_<arch>.deb.mldsa65.sig`: an ML-DSA-65 (FIPS 204) signature over the same bytes, made with a second key whose public half will be in [`keyring/glyndor-release-mldsa65.b64`](../keyring/glyndor-release-mldsa65.b64). It is added beside the Ed25519 signature and never replaces it, so a package is good only when both verify. From the first release that carries it, every later release does: the release workflow refuses to publish one without it.

Checking it needs OpenSSL 3.5 or later. The key file holds a raw 1952-byte ML-DSA-65 public key in base64, and the steps below put the standard 22-byte DER header in front of it to get a key OpenSSL reads. The file has one key per line, and two during a key rotation; the steps take the first, and a package is good when either verifies it. With `deb` and `base` set as above:

```bash
key="$(curl -sSf https://raw.githubusercontent.com/Glyndor/podman/main/keyring/glyndor-release-mldsa65.b64 | grep -v '^#' | head -n 1)"
{ printf '\x30\x82\x07\xb2\x30\x0b\x06\x09\x60\x86\x48\x01\x65\x03\x04\x03\x12\x03\x82\x07\xa1\x00'
  printf '%s' "$key" | base64 -d; } | openssl pkey -pubin -inform DER -out glyndor-release-mldsa65.pem

curl -sSfLO "$base/$deb.mldsa65.sig"
openssl pkeyutl -verify -pubin -inkey glyndor-release-mldsa65.pem -rawin -in "$deb" -sigfile "$deb.mldsa65.sig"
```

The answers are the same two as for the first signature.

## Check the build provenance

Releases also carry a build provenance attestation, which says which workflow run of this repository built the package:

```bash
gh attestation verify "$deb" --repo Glyndor/podman
```
