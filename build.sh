#!/bin/sh
# Builds the installable module zip from module/.
set -e
cd "$(dirname "$0")/module"
v=$(sed -n 's/^version=//p' module.prop)
out="../dex-display-control-$v.zip"
rm -f "$out"
zip -qr -X "$out" META-INF module.prop customize.sh service.sh post-fs-data.sh uninstall.sh display.sh webroot
echo "$out"
