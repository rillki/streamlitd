/// Exceptions used for control flow and API errors.
module streamlitd.errors;

/// Thrown inside the app function to abort the current run so that a new run can start.
class RerunException : Exception
{
	this(string file = __FILE__, size_t line = __LINE__) { super("rerun", file, line); }
}

/// Thrown by `st.stop()` to end the current run.
class StopException : Exception
{
	this(string file = __FILE__, size_t line = __LINE__) { super("stop", file, line); }
}

/// Raised when the app uses the API incorrectly (e.g. duplicate widget ids).
class StreamlitAPIException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// Two widgets resolved to the same id.
class DuplicateWidgetID : StreamlitAPIException
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}
