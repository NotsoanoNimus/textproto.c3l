module textproto;

import std::io;

<* An interface inheriting from both In and Out `std::io` stream types. *>
interface InOutStream : InStream, OutStream {}

<* Function pointer type used in some textproto hooks to validate incoming lines. *>
alias LineValidationFunc = fn bool? (String, usz);
