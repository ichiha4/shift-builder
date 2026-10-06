from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
directory = root / "ShiftManagerApp" / "ShiftManagerApp"
destination = directory / "GoogleService-Info.plist"
if destination.exists():
    print("Existing Firebase configuration preserved.")
else:
    shutil.copyfile(directory / "GoogleService-Info.example.plist", destination)
    print("Placeholder configuration created for the LocalDevice scheme.")
print("Open the Xcode project and select ShiftManagerApp-LocalDevice.")
print("The placeholder is not valid for Firebase sign-in or cloud sync.")
