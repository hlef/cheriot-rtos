// Copyright CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#define TEST_NAME "Test check_pointer"
#include "check_pointer.h"
#include "tests.hh"

int object;

void test_check_pointer()
{
	check_pointer_strict_mode_inner(&object);
}
