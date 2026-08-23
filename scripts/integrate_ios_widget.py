#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"{path.relative_to(ROOT)}: already integrated")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ABORT: expected exactly one integration anchor in {path}, found {count}"
        )
    path.write_text(text.replace(old, new, 1))
    print(f"{path.relative_to(ROOT)}: integrated")

app_delegate = ROOT / "ios/Runner/AppDelegate.swift"
replace_once(
    app_delegate,
    """        // Set up method channel for Siri media intent handling
        setupSiriIntentChannel()
""",
    """        // Set up method channel for Siri media intent handling
        setupSiriIntentChannel()

        // Synchronize Now Playing state with the WidgetKit extension.
        setupWidgetChannel()
""",
)

background_task = ROOT / "lib/services/music_player_background_task.dart"
replace_once(
    background_task,
    """import 'ios_helpers.dart';
import 'metadata_provider.dart';
""",
    """import 'ios_helpers.dart';
import 'ios_widget_service.dart';
import 'metadata_provider.dart';
""",
)

replace_once(
    background_task,
    """    GetIt.instance<ProviderContainer>().listen<bool>(
      finampSettingsProvider.showStarRatings,
      (_, _) => _handleStarRatingSettingChanged(),
    );

    if (Platform.isWindows || Platform.isLinux) {
""",
    """    GetIt.instance<ProviderContainer>().listen<bool>(
      finampSettingsProvider.showStarRatings,
      (_, _) => _handleStarRatingSettingChanged(),
    );

    unawaited(IosWidgetService.instance.initialize(audioHandler: this));

    if (Platform.isWindows || Platform.isLinux) {
""",
)

subprocess.run(
    ["ruby", str(ROOT / "scripts/install_ios_widget.rb")],
    cwd=ROOT,
    check=True,
)

print("Widget integration complete.")
