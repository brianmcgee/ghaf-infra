# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
#
# SPDX-License-Identifier: Apache-2.0
{
  users.users = {
    hrosten = {
      isNormalUser = true;
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHFuB+uEjhoSdakwiKLD3TbNpbjnlXerEfZQbtRgvdSz"
      ];
      extraGroups = ["wheel" "networkmanager"];
    };
  };
}
