"""The workspace: one part, its stock, setups, toolpaths and playback (port of AppModel and its
extensions in Model/*.swift). Each mixin is one Swift file."""


def __getattr__(name):
    if name == "Workspace":
        from .workspace import Workspace
        return Workspace
    raise AttributeError(name)
