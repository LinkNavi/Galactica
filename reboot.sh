./make-iso.sh

qemu-img create -f raw test-install.img 3G

# Re-extract from new ISO
rm -rf /tmp/iso-extract
7z x galactica-installer.iso -o/tmp/iso-extract boot/vmlinuz boot/initrd.img

qemu-system-x86_64 \
  -m 2G \
  -cpu qemu64 \
  -drive file=test-install.img,format=raw,if=ide,cache=none \
  -display gtk \
  -kernel /tmp/iso-extract/boot/vmlinuz \
  -initrd /tmp/iso-extract/boot/initrd.img \
  -append "root=/dev/ram0 rw console=tty0 quiet" \
  -no-reboot
