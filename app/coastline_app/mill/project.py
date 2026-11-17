"""A guided job's steps, as the sender runs them. Port of MillCore/Project/Project.swift
(`Operation`/`Job` in the original's .crproj format)."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field


def new_id() -> str:
    return str(uuid.uuid4()).upper()


@dataclass
class Step:
    """One step ("operation") of a guided job."""

    manifest: str  # the manifest file this step came from (`manifest.yml` or a sub-manifest)
    splice_index: int | None = None
    title: str = ""
    prompt: str = ""  # `step_text`: plain text shown when there is no markdown
    markdown: str = ""
    image_path: str = ""
    gcode_path: str = ""
    pause: bool = False
    reset: bool = False
    timeout: int = 0
    unskippable: str = ""  # "true" by popup_text
    popup_text: str = ""
    popup_title: str = ""
    popup_wait_time: int = 0
    popup_yes_step: str = ""  # absolute index or relative +n/-n
    popup_no_step: str = ""
    go_to: str = ""
    condition_name: str | None = None
    condition_value: int = 0
    id: str = field(default_factory=new_id, compare=False)

    @staticmethod
    def placeholder(manifest: str) -> "Step":
        return Step(manifest, title="Step Name", markdown="\nStep Text", prompt="Please update the software that runs this job.")

    @property
    def has_gcode(self) -> bool:
        return bool(self.gcode_path)

    @property
    def is_unskippable(self) -> bool:
        return self.unskippable == "true"

    @property
    def has_popup(self) -> bool:
        return bool(self.popup_text)


@dataclass
class WCSCheck:
    wcs: int  # 54…59, or -1 when missing
    x: float
    y: float
    z: float


@dataclass
class Job:
    title: str = ""
    prompt: str = ""
    steps: list[Step] = field(default_factory=list)
    guide_files: list[str] = field(default_factory=list)
    model_files: list[str] = field(default_factory=list)
    min_firmware_version: str = ""
    min_sender_version: str = ""
    allow_wcs_clear_prompt: bool = True
    wcs_checks: list[WCSCheck] = field(default_factory=list)
    wcs_check_failed_message: str = ""
    id: str = field(default_factory=new_id, compare=False)

    @property
    def uses_submanifests(self) -> bool:
        return any(s.manifest != "manifest.yml" for s in self.steps)
