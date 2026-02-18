LOOP=$(sudo losetup -fP --show GalacticaInstaller/test-disk.img)

# Check boot partition
sudo mount ${LOOP}p1 /mnt/gboot
ls -la /mnt/gboot
cat /mnt/gboot/grub/grub.cfg
sudo umount /mnt/gboot

# Check root partition
sudo mkdir -p /mnt/groot
sudo mount ${LOOP}p3 /mnt/groot
ls -la /mnt/groot
ls -la /mnt/groot/sbin/
sudo umount /mnt/groot

sudo losetup -d $LOOP
