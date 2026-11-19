#!/bin/sh
# 编出四个二进制放进 ../bin/，再打出各自的 SHA-256（ADR 决定四）。二进制随仓库提交：改了源码就跑这个脚本，把四个二进制一起提交。Go 是 1.27.3（go.mod 的 toolchain 一行，mise.toml 也钉在这个版本），
# 只用标准库，CGO_ENABLED=0、-trimpath、-buildvcs=false、-ldflags="-s -w"：同样的源码、Go 版本和参数，谁编出来哈希都一样。
# 源码要按 LF 检出（.gitattributes），Windows 上的 Git 默认会转成 CRLF，那样编出来的哈希就对不上。
set -eu
cd "$(dirname -- "$0")"
for target in darwin/arm64 darwin/amd64 windows/amd64 windows/arm64; do
  os=${target%/*}
  arch=${target#*/}
  out=../bin/capture-$os-$arch
  [ "$os" = windows ] && out=$out.exe
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -buildvcs=false -ldflags="-s -w" -o "$out" .
done
cd ../bin
if command -v sha256sum >/dev/null 2>&1; then sha256sum capture-*; else shasum -a 256 capture-*; fi
