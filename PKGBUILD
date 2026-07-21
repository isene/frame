# Maintainer: Geir Isene <g@isene.com>
pkgname=frame
pkgver=0.0.143
pkgrel=1
pkgdesc="X11 display server in x86_64 assembly. DRM/KMS + evdev direct, no libc, no Mesa. Experimental."
arch=('x86_64')
url="https://github.com/isene/frame"
license=('Unlicense')
makedepends=('binutils' 'nasm')
source=("$pkgname-$pkgver.tar.gz::https://github.com/isene/frame/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
    cd "frame-$pkgver"
    make
    strip frame
}

package() {
    cd "frame-$pkgver"
    make PREFIX=/usr DESTDIR="$pkgdir" install
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
