#! /usr/bin/env bash
#TMPDIR=/virtual_machines/tmp/ packer build -except=qemu -var-file=../../../private_vars.json -var-file=box_info.json -var-file=template.json ../../arch-server.json
TMPDIR=/virtual_machines/tmp/ packer build -machine-readable -only=qemu -var-file=../../../private_vars.json -var-file=box_info.json -var-file=template.json ../../arch-server.json