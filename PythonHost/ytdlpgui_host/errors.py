"""The error the host reports back to the app instead of raising."""


class HostError(Exception):
    """A problem `dispatch` turns into `{"ok": false, "error": <message>}`.

    Raised for anything the app (or the person using it) can act on — bad arguments, an engine
    that isn't configured, a failed update — so the message is written as a sentence for people,
    and no traceback is attached.
    """
