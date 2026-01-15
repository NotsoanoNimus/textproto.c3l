module textproto;

import std::io;

<* An interface inheriting from both In and Out `std::io` stream types. *>
interface InOutStream : InStream, OutStream {}

<* Function pointer type used in some textproto hooks to validate incoming lines. *>
alias LineValidationFunc = fn bool? (String, usz);

faultdef NO_FAULT_OUTCOME @local;

<* A piece of data *>
struct Outcome @generic(Type)
{
	inline Type value;
	fault condition;
}

macro Outcome{Type} @outcome(Type #value = ..., fault #error = ...) @generic(Type) @builtin
	=> {
		.value = $defined(#value) ??? #value : (Type){},
		.condition = $defined(#error) ??? #error : NO_FAULT_OUTCOME
	};

// fn void? Outcome.unwrap(&self) => self.condition != NO_FAULT_OUTCOME ? (self.condition?) : void;
fn Type? Outcome.unwrap(&self)
{
	if (self.condition != NO_FAULT_OUTCOME) return self.condition~;
	return self.value;
}

macro Outcome{Type} wrap(#func, ...) @generic(Type) @builtin @safemacro
{
	Type? result = #func($vasplat);
	if (catch err = result) return @outcome(#error: err);
	return @outcome(result);
}

