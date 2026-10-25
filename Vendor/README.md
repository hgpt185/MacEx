# Bundled SSH dependencies

`SSHDependencies.xcframework` contains a static universal library for macOS 14+, combining libssh2 and OpenSSL Crypto. It is linked into MacEx; users need no Homebrew installation, system libssh2, external SSH executable, or runtime dylib download. App-owned SFTP sessions never launch a shell or enable agent forwarding.

Pins are recorded in `ssh-dependencies.json`: OpenSSL 3.5.9 LTS and libssh2 commit `6e7b2076a6ced2230968b27ee7c1abb77fe5a88d` (upstream development snapshot following 1.11.1). This deliberately identifies the exact source snapshot rather than calling it a newer stable release. See [OpenSSL downloads](https://www.openssl-library.org/source/), [libssh2 source](https://github.com/libssh2/libssh2/tree/6e7b2076a6ced2230968b27ee7c1abb77fe5a88d), and [upstream security policy](https://github.com/libssh2/libssh2/security/policy). These pins and the integration checks are not an independent professional security audit.

## Rebuild

```sh
python3 Scripts/build-ssh-dependencies.py
```

Requires macOS, Command Line Tools, Python 3, Perl, and Make. The script installs pinned CMake into `.build/ssh-tools` when needed, verifies SHA-256 for both source archives before extracting, builds each architecture with a 14.0 deployment target, and combines the static archives into the checked-in XCFramework. Build inputs/commands are recorded in `.build/ssh-build.log`. Downloads, intermediate sources, and tool environments stay in `.build`; they are not bundled. OpenSSL is built without shared modules, legacy provider, engines, apps, or tests. Only its Crypto archive is included. libssh2 examples, tracing, zlib compression, and test tools are disabled in the shipped dependency build. The hash-pinned MacEx patch in `patches/` makes Unix-agent socket connection nonblocking; app I/O callbacks apply cancellation/deadlines to agent reads and writes. A busy agent connection fails instead of blocking a worker indefinitely. Compiler/SDK differences can change binary bytes; the script provides reproducible source/configuration inputs, not a bit-for-bit reproducibility claim across toolchains.

## Notices

`Notices/libssh2-LICENSE.txt` (BSD-3-Clause), `Notices/OpenSSL-LICENSE.txt` (Apache-2.0), and `Notices/VERSIONS.json` are copied into each app bundle by the packaging script. The project's MIT license applies to MacEx's own code; it does not replace dependency licenses.

## Security updates

Before publishing each preview, review upstream libssh2 security information/commits and OpenSSL supported-release/security notes. For a relevant update: select an explicit reviewed upstream release/commit, obtain its archive digest from the upstream release metadata and verify the downloaded bytes, update the lock file and build script's source filename handling if needed, rebuild both architectures, refresh notices, rerun all SFTP fixtures and native trust/transfer checks, then inspect the binary for architecture/minimum-OS/runtime dependencies before packaging. Do not advance dependencies silently, use moving branches as download inputs, or enable weak algorithm fallback to work around a failure. Track any source modifications as reviewed patches with hashes and keep changes separate from upstream pins. No automatic dependency update or network fetch occurs at app launch.
