// Copyright CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#define TEST_NAME "Test misc APIs"
#include "tests.hh"
#include <compartment-macros.h>
#include <ds/pointer.h>
#include <stdlib.h>
#include <string.h>
#include <timeout.h>

using namespace CHERI;

namespace
{

	/**
	 * Test timeouts.
	 *
	 * This test checks the following:
	 *
	 * - A timeout of zero would not block.
	 * - `elapse` saturates values, i.e., a `remaining` value of zero will still
	 * be zero after a call to `elapse`, and an `elapsed` value of `UINT32_MAX`
	 *   would still be `UINT32_MAX` after a call to `elapse`.
	 * - An unlimited timeout is really unlimited, i.e., a call to `elapse` does
	 *   not modify its `remaining` value, which blocks.
	 */
	void check_timeouts()
	{
		debug_log("Test timeouts.");

		// Create a zero timeout.
		Timeout t{0};
		// Ensure that a zero timeout does not block.
		TEST(!t.may_block(), "A zero timeout should not block.");

		// Create a zero timer with maximum elapsed time.
		t = Timeout{UINT32_MAX /* elapsed */, 0 /* remaining */};
		// Ensure that a call to `elapse` saturates both `elapsed` and
		// `remaining`.
		t.elapse(42);
		TEST(
		  t.remaining == 0,
		  "`elapse` does not saturate the `remaining` value of a zero timer.");
		TEST(t.elapsed == UINT32_MAX,
		     "`elapse` does not saturate the `elapsed` value of a zero timer.");

		// Create an unlimited timeout.
		t = Timeout{UnlimitedTimeout /* remaining */};
		// Ensure that a call to `elapse` does not modify the `remaining` value
		// of the unlimited timeout.
		t.elapse(42);
		TEST(t.remaining == UnlimitedTimeout,
		     "`elapse` alters the remaining value of an unlimited timeout.");
		// Ensure that an unlimited timeout blocks.
		TEST(t.may_block(), "An unlimited timeout should block.");
	}

	/**
	 * Test memchr.
	 *
	 * This test checks the following:
	 *
	 * - memchr finds the first occurrence of the character when it is present
	 *   (test for different values, particularly the first and the last one).
	 * - memchr returns NULL when the string does not contain the character
	 * (test for non-NULL terminated string).
	 * - memchr does not stop at \0 characters.
	 * - memchr returns NULL for 0-size pointers.
	 */
	void check_memchr()
	{
		debug_log("Test memchr.");

		char string[] = {'C', 'H', 'E', 'R', 'R', 'I', 'E', 'S'};

		TEST(memchr(string, 'C', sizeof(string)) == &string[0],
		     "memchr must return the first occurence of the character.");
		TEST(memchr(string, 'R', sizeof(string)) == &string[3],
		     "memchr must return the first occurence of the character.");
		TEST(memchr(string, 'S', sizeof(string)) == &string[7],
		     "memchr must return the first occurence of the character.");
		TEST(memchr(string, 'X', sizeof(string)) == NULL,
		     "memchr must return NULL when a character is not present.");

		char stringWithNull[] = {'Y', 'E', 'S', '\0', 'N', 'O', '\0'};

		TEST(memchr(stringWithNull, 'N', sizeof(stringWithNull)) ==
		       &stringWithNull[4],
		     "memchr must not stop at NULL characters.");

		TEST(memchr(stringWithNull, 'N', 0) == NULL,
		     "memchr must return NULL for zero-size pointers.");
	}

	/**
	 * Test memrchr.
	 *
	 * This test checks the following:
	 *
	 * - memrchr finds the first occurrence of the character when it is present
	 *   (test for different values, particularly the first and the last one).
	 * - memrchr returns NULL when the string does not contain the character
	 * (test for non-NULL terminated string).
	 * - memrchr does not stop at \0 characters.
	 * - memrchr returns NULL for 0-size pointers.
	 */
	void check_memrchr()
	{
		debug_log("Test memrchr.");

		char string[] = {'C', 'H', 'E', 'R', 'R', 'I', 'O', 'T'};

		TEST(memchr(string, 'C', sizeof(string)) == &string[0],
		     "memrchr must return the first occurence of the character.");
		TEST(memrchr(string, 'R', sizeof(string)) == &string[4],
		     "memrchr must return the first occurence of the character.");
		TEST(memrchr(string, 'T', sizeof(string)) == &string[7],
		     "memrchr must return the first occurence of the character.");
		TEST(memrchr(string, 'X', sizeof(string)) == NULL,
		     "memrchr must return NULL when a character is not present.");

		char stringWithNull[] = {'F', 'U', '\0', 'B', 'A', 'R', '\0'};

		TEST(memrchr(stringWithNull, 'F', sizeof(stringWithNull)) ==
		       &stringWithNull[0],
		     "memrchr must not stop at NULL characters.");

		TEST(memrchr(stringWithNull, 'Y', 0) == NULL,
		     "memrchr must return NULL for zero-size pointers.");
	}

	/**
	 * Test strto{,u}l
	 */
	void check_strtol()
	{
		const char *p;
		char       *r;

		debug_log("Test strtol.");

		TEST_EQUAL(strtol("0", nullptr, 10), 0, "strtol 0");
		TEST_EQUAL(
		  strtoul("4294967295", nullptr, 10), 4294967295, "strtoul UINT_MAX");
		TEST_EQUAL(
		  strtol("-2147483648", nullptr, 10), -2147483648, "strtol INT_MIN");
		TEST_EQUAL(strtol("-1", nullptr, 0), -1, "strtol -1");

		p = "0x123 45";
		TEST_EQUAL(strtoul(p, &r, 0), 0x123, "strtoul prefix");
		TEST_EQUAL(r, p + 5, "strtoul out pointer");
	}

	/**
	 * Test pointer utilities.
	 *
	 * Not comprehensive, would benefit from being expanded at some point.
	 */
	void check_pointer_utilities()
	{
		debug_log("Test pointer utilities.");

		int                              integer        = 42;
		int                             *integerPointer = &integer;
		ds::pointer::proxy::Pointer<int> pointer{integerPointer};

		TEST((pointer == integerPointer) && (*pointer == 42),
		     "The pointer proxy does not return the value of its proxy.");

		int  anotherInteger        = -100;
		int *anotherIntegerPointer = &anotherInteger;
		ds::pointer::proxy::Pointer<int> anotherPointer{anotherIntegerPointer};

		pointer = anotherPointer;

		TEST(
		  (pointer == anotherIntegerPointer) && (*pointer == -100),
		  "The pointer proxy `=` operator does not correctly set the pointer.");
	}

	void check_shared_object(const char      *name,
	                         Capability<void> object,
	                         size_t           size,
	                         PermissionSet    permissions)
	{
		debug_log("Checking shared object {}.", object);
		TEST(object.length() == size,
		     "Object {} is {} bytes, expected {}",
		     name,
		     object.length(),
		     size);
		TEST(object.permissions() == permissions,
		     "Object {} has permissions {}, expected {}",
		     name,
		     PermissionSet{object.permissions()},
		     permissions);
	}

	// This test is somewhat intimately familiar with parameters of CHERIoT's
	// capability encoding and so might need revision if that changes.
	void check_capability_set_inexact_at_most()
	{
		void *p = malloc(3128);

		debug_log("Test Capability::BoundsProxy::set_inexact_at_most with {}",
		          p);

		// Too many bits for mantissa, regardless of base alignment
		{
			Capability<void> q      = {p};
			size_t           reqlen = 2047;
			q.bounds().set_inexact_at_most(reqlen);
			debug_log("Requesting 2047 gives {}: {}", q.length(), q);
			TEST(q.is_valid(), "set_inexact_at_most untagged");
			TEST(q.length() < 2047, "set_inexact_at_most failed to truncate");
			TEST(q.base() == q.address(), "set_inexact_at_most nonzero offset");
		}

		// Fits in mantissa, but not reachable from misaligned base
		{
			Capability<void> q = {p};
			q.address() += 2;
			size_t reqlen = 1024;
			q.bounds().set_inexact_at_most(reqlen);
			debug_log("Requesting 1024 at align 2 gives {}: {}", q.length(), q);
			TEST(q.is_valid(), "set_inexact_at_most untagged");
			TEST(q.length() < 1024, "set_inexact_at_most failed to truncate");
			TEST(q.base() == q.address(), "set_inexact_at_most nonzero offset");
		}

		// Fits in mantissa and reachable from misaligned base
		{
			Capability<void> q = {p};
			q.address() += 1;
			size_t reqlen = 511;
			q.bounds().set_inexact_at_most(reqlen);
			debug_log("Requesting 511 at align 1 gives {}: {}", q.length(), q);
			TEST(q.is_valid(), "set_inexact_at_most untagged");
			TEST(q.length() == 511,
			     "set_inexact_at_most truncated unnecessarily");
			TEST(q.base() == q.address(), "set_inexact_at_most nonzero offset");
		}

		free(p);
	}

	/**
	 * This is a regression test for #368.  There are many different ways for
	 * the compiler to generate a memcmp call and this manages to trigger one of
	 * the ones that wasn't being mangled the same way as others.  The run-time
	 * behaviour of this test is irrelevant, we should get a linker failure if
	 * the freestanding library and the compiler disagree on function names.
	 */
	void check_odd_memcmp()
	{
		std::string first  = "first";
		std::string second = "second";
		TEST((first == second) == false,
		     "This test should never fail but exists to make sure that a "
		     "comparison result is used");
	}

	/**
	 * Test CILS accessors
	 */
	void check_cils()
	{
		int   x;
		void *p = &x;

		TEST(__builtin_cheri_equal_exact(nullptr, *invocation_state_slot(0)),
		     "CILS nonzero pointer 0 on entry");

		TEST(__builtin_cheri_equal_exact(nullptr, *invocation_state_slot(1)),
		     "CILS nonzero pointer 1 on entry");

		*invocation_state_slot(1) = p;
		TEST(__builtin_cheri_equal_exact(p, invocation_state<int>()),
		     "CILS failed to store stack pointer");
	}

	const char *testString = "Hello world";

} // namespace

volatile decltype(testString) *volatileString = &testString;

void check_sealed_scoping()
{
	Capability<void> o{switcher_current_thread()};
	TEST(o.is_valid() && (o.type() == CheriSealTypeSealedTrustedStacks),
	     "Shared object cap not as expected: {}",
	     o);

	// Take the address of the o cap, requiring that it go out to memory.
	Capability<Capability<void>> oP{&o};

	/*
	 * Load a copy of our sealed o cap through an authority that lacks
	 * LoadGlobal permission.  The result should be identical to the original
	 * but without global permission.
	 */
	Capability<Capability<void>> oPNoLoadGlobal = oP;
	oPNoLoadGlobal.without_permissions(Permission::LoadGlobal);
	const Capability<void> OLocal1 = *oPNoLoadGlobal;

	TEST(OLocal1.is_valid(),
	     "Loading global sealed cap through non-LoadGlobal invalid");
	TEST_EQUAL(OLocal1.type(),
	           o.type(),
	           "Loading global sealed cap through non-LoadGlobal bad type");
	TEST_EQUAL(OLocal1.permissions(),
	           o.permissions().without(Permission::Global),
	           "Loading global sealed cap through non-LoadGlobal bad perms");

#ifndef CHERIOT_NO_SAIL_83
	/*
	 * Use CAndPerm to shed Global from our o cap.
	 * Spell this a little oddly to make sure we get CAndPerm with a mask of
	 * all 1s but Global.  Using oLocal2.permissions().without() would do a
	 * cgetperm and then candperm.
	 */
	Capability<void> oLocal2 = o;
	oLocal2.without_permissions(Permission::Global);

	TEST_EQUAL(oLocal2, OLocal1, "CAndPerm ~GL gone wrong");
#else
	debug_log(
	  "Skipping test for cheriot-sail#83 because the ISA version is too old.");
#endif
}

int test_misc()
{
	{
		// Inspect the return sentry the switcher gave us.  Unlike the one given
		// to run_tests() (over in the "test_runner" compartment), this one is
		// not a thread entry vector, and so is computed by cjalr in
		// compartment_switcher_entry.
		Capability switcherReturnSentry{__builtin_return_address(0)};
		TEST(!switcherReturnSentry.permissions().contains(Permission::Global),
		     "Switcher return sentry should be local");
	}

	check_timeouts();
	check_memchr();
	check_memrchr();
	check_strtol();
	check_pointer_utilities();
	check_capability_set_inexact_at_most();
	check_sealed_scoping();
	check_cils();

	debug_log("Testing shared objects.");
	check_shared_object("exampleK",
	                    SHARED_OBJECT(void, exampleK),
	                    1024,
	                    {Permission::Global,
	                     Permission::Load,
	                     Permission::Store,
	                     Permission::LoadStoreCapability,
	                     Permission::LoadMutable});
	check_shared_object(
	  "exampleK",
	  SHARED_OBJECT_WITH_PERMISSIONS(void, exampleK, true, true, false, false),
	  1024,
	  {Permission::Global, Permission::Load, Permission::Store});
	check_shared_object(
	  "test_word",
	  SHARED_OBJECT_WITH_PERMISSIONS(void, test_word, true, false, true, false),
	  4,
	  {Permission::Global, Permission::Load, Permission::LoadStoreCapability});
	check_shared_object("test_word",
	                    SHARED_OBJECT_WITH_PERMISSIONS(
	                      void, test_word, true, false, false, false),
	                    4,
	                    {Permission::Global, Permission::Load});
	check_odd_memcmp();
	TEST_EQUAL(strnlen(*volatileString, 3),
	           3,
	           "Incorrect length from strnlen with length shorter than string");
	TEST_EQUAL(
	  strnlen(*volatileString, SIZE_MAX),
	  11,
	  "Incorrect length from strnlen with length longer than the string");
	return 0;
}
