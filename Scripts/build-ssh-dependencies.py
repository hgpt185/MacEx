#!/usr/bin/env python3
"""Build pinned, static SSH dependencies for macOS. No runtime Homebrew dependency."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / 'Vendor/ssh-dependencies.json'
pins = json.loads(LOCK.read_text())
work = ROOT / '.build/ssh-sources'
work.mkdir(parents=True, exist_ok=True)
log_path = ROOT / '.build/ssh-build.log'

def run(args, cwd=None, env=None):
    with log_path.open('ab') as log:
        log.write(('\n$ ' + ' '.join(map(str, args)) + '\n').encode()); log.flush()
        subprocess.run(list(map(str, args)), cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)

def source(name):
    pin = pins[name]
    filename = 'openssl-3.5.9.tar.gz' if name == 'openssl' else 'libssh2-6e7b207.tar.gz'
    archive = work / filename
    if not archive.exists():
        print('Downloading ' + name, flush=True)
        urllib.request.urlretrieve(pin['url'], archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != pin['sha256']:
        raise SystemExit('Checksum mismatch: ' + str(archive))
    with tarfile.open(archive) as tar:
        top = tar.getmembers()[0].name.split('/')[0]
        destination = work / top
        if destination.exists():
            shutil.rmtree(destination)
        if not destination.exists():
            # Pinned upstream source archives; still reject path traversal and escaping links.
            for member in tar.getmembers():
                target = (work / member.name).resolve()
                if work.resolve() not in target.parents:
                    raise SystemExit('Unsafe archive path')
                if member.issym() or member.islnk():
                    linked = (target.parent / member.linkname).resolve()
                    if work.resolve() not in linked.parents:
                        raise SystemExit('Unsafe archive link')
            tar.extractall(work)
    return destination

openssl = source('openssl')
ssh = source('libssh2')
for patch in pins.get('patches', []):
    file = ROOT / 'Vendor/patches' / patch['file']
    if hashlib.sha256(file.read_bytes()).hexdigest() != patch['sha256']:
        raise SystemExit('Patch checksum mismatch: ' + str(file))
    run(['patch', '-p1', '-i', file], cwd=ssh)
cmake = ROOT / '.build/ssh-tools/bin/cmake'
if not cmake.exists():
    print('Installing pinned CMake into .build/ssh-tools', flush=True)
    run(['python3', '-m', 'venv', ROOT / '.build/ssh-tools'])
    run([ROOT / '.build/ssh-tools/bin/python', '-m', 'pip', 'install', 'cmake==' + pins['cmake']])

sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
cc = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
flags = '-O2 -g0 -mmacosx-version-min=14.0'
crypto_cache = hashlib.sha256((json.dumps(pins['openssl'], sort_keys=True) + flags + sdk).encode()).hexdigest()[:12]
archives = []
for arch in ('arm64', 'x86_64'):
    print('Building SSH dependencies: ' + arch + ' (details in .build/ssh-build.log)', flush=True)
    build = work / ('openssl-build-' + crypto_cache + '-' + arch)
    build.mkdir(exist_ok=True)
    install = work / ('openssl-install-' + crypto_cache + '-' + arch)
    env = dict(os.environ, CC=cc, CFLAGS=flags + ' -arch ' + arch + ' -isysroot ' + sdk,
               MACOSX_DEPLOYMENT_TARGET='14.0', ZERO_AR_DATE='1')
    if not (install / 'lib/libcrypto.a').exists():
        run(['perl', openssl / 'Configure', 'darwin64-' + arch + '-cc', 'no-shared', 'no-tests',
             'no-module', 'no-legacy', 'no-engine', 'no-apps', 'no-docs', '--prefix=' + str(install), '--libdir=lib'], cwd=build, env=env)
        run(['make', '-j4', 'build_libs'], cwd=build, env=env)
        run(['make', 'install_dev'], cwd=build, env=env)
    ssh_build = work / ('libssh2-build-' + arch)
    run([cmake, '-S', ssh, '-B', ssh_build, '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=' + arch,
         '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', '-DCMAKE_OSX_SYSROOT=' + sdk,
         '-DCMAKE_C_COMPILER=' + cc, '-DCMAKE_C_FLAGS=' + flags,
         '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_STATIC_LIBS=ON', '-DBUILD_EXAMPLES=OFF', '-DBUILD_TESTING=OFF',
         '-DLIBSSH2_BUILD_DOCS=OFF', '-DENABLE_DEBUG_LOGGING=OFF', '-DCRYPTO_BACKEND=OpenSSL',
         '-DOPENSSL_ROOT_DIR=' + str(install), '-DOPENSSL_USE_STATIC_LIBS=ON',
         '-DOPENSSL_CRYPTO_LIBRARY=' + str(install / 'lib/libcrypto.a'), '-DOPENSSL_INCLUDE_DIR=' + str(install / 'include'),
         '-DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=TRUE'], env=env)
    run([cmake, '--build', ssh_build, '-j4'], env=env)
    output = work / ('libMacExSSH-' + arch + '.a')
    run(['libtool', '-static', '-o', output, ssh_build / 'src/libssh2.a', install / 'lib/libcrypto.a'], env=env)
    archives.append(output)

framework = ROOT / 'Vendor/SSHDependencies.xcframework'
slice_dir = framework / 'macos-arm64_x86_64'
headers = slice_dir / 'Headers'
headers.mkdir(parents=True, exist_ok=True)
run(['lipo', '-create', *archives, '-output', slice_dir / 'libMacExSSH.a'])
for filename in ('libssh2.h', 'libssh2_sftp.h'):
    shutil.copy2(ssh / 'include' / filename, headers / filename)
(headers / 'module.modulemap').write_text('module SSHDependencies {\n  header "libssh2.h"\n  header "libssh2_sftp.h"\n  export *\n}\n')
(framework / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0',
    'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64_x86_64', 'LibraryPath': 'libMacExSSH.a',
                            'HeadersPath': 'Headers', 'SupportedArchitectures': ['arm64', 'x86_64'], 'SupportedPlatform': 'macos'}]
}))
notices = ROOT / 'Vendor/Notices'
notices.mkdir(exist_ok=True)
shutil.copy2(ssh / 'COPYING', notices / 'libssh2-LICENSE.txt')
source_notices = []
for directory in ('src', 'include'):
    for file in sorted((ssh / directory).glob('*')):
        if file.suffix not in ('.c', '.h'):
            continue
        text = file.read_text(errors='replace').lstrip()
        if text.startswith('/*') and '*/' in text:
            source_notices.append(str(file.relative_to(ssh)) + '\n' + text.split('*/', 1)[0] + '*/\n')
(notices / 'libssh2-SOURCE-NOTICES.txt').write_text('Upstream source-file notices (including code not selected by this build).\n\n' + '\n'.join(source_notices))
shutil.copy2(openssl / 'LICENSE.txt', notices / 'OpenSSL-LICENSE.txt')
(notices / 'VERSIONS.json').write_bytes(LOCK.read_bytes())
print('Built ' + str(framework), flush=True)
