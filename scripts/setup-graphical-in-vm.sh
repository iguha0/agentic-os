#!/bin/sh
# The old in-VM installer duplicated boot logic and generated a Gemma-era
# initramfs. Keep this entry point only to direct users to the supported build.

echo "The in-VM graphical installer has been retired."
echo ""
echo "On the host Mac, run:"
echo "  ./build-graphical-rootfs.sh"
echo "  ./create-data-disk.sh"
echo "  ./launch-graphical.sh"
echo ""
echo "This preserves the working Qwen boot path and persistent Agentic OS state."
exit 1
