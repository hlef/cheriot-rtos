// Copyright CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#include <compartment.h>

void __cheri_compartment("check_pointer_inner")
  check_pointer_strict_mode_inner(int *obj);
