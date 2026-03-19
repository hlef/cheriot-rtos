Privileged Libraries
====================

Privileged libraries are a mechanism that allows libraries to hold loader-provided sealing keys.
Privileged libraries expose certain privileged operations to unprivileged compartments without the need to perform a full compartment switch.
This allows to avoid the switcher and its associated overheads, which is desirable from a performance perspective.

Privileged libraries vs. libraries
----------------------------------

Protected libraries are, for the better part, normal CHERIoT libraries.
This means that...
- they are semantically equivalent to having a copy of the code of the library in the calling compartment;
- they are entered via a direct sentry call: compartments have a sentry capability to the library in their import table and do not need to go through the switcher to call it;
- they do not have global state.

The core difference with normal libraries is that protected libraries have may have up to three capability authorizing use of a hardware sealing type placed before their import table.
For example, the token API (a privileged library) stores the sealing keys used for statically-sealed and dynamically-sealed objects in these slots.

Protected libraries can access this secret via PC-relative addressing.
Compartments cannot access the secret from outside the context of the library since the capability that allows them to jump into the protected library is sealed (it is a *sentry* capability).

Writing privileged libraries
----------------------------

Since protected libraries are *libraries*, the switcher does not automatically clear registers when leaving the protected library.
This creates a risk that the protected library would leak its secrets to the caller through uncleared registers when returning to the caller.
For this reason, protected libraries such as the token API are written in carefully-audited assembly that "manually" manages its registers to avoid leaks.
The implementation of the token API is somewhat paranoiac and runs with interrupts disabled, but this is not needed in the general case.
