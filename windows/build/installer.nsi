Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma
!include "MUI2.nsh"
!define PRODUCT_NAME "Alembic"
!define PRODUCT_VERSION "1.0.0"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Alembic"
Name "${PRODUCT_NAME}"
OutFile "..\release\Alembic-1.0.0-Windows-x64-Setup.exe"
InstallDir "$LOCALAPPDATA\Programs\Alembic"
InstallDirRegKey HKCU "Software\Luke McLaughlin\Alembic" "InstallLocation"
Icon "icon.ico"
UninstallIcon "icon.ico"
BrandingText "Alembic for Windows 10/11"
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "1.0.0.1"
VIAddVersionKey /LANG=1033 "ProductName" "Alembic"
VIAddVersionKey /LANG=1033 "CompanyName" "Luke McLaughlin"
VIAddVersionKey /LANG=1033 "FileDescription" "Local dataset preparation and RAG chunking for Windows"
VIAddVersionKey /LANG=1033 "FileVersion" "1.0.0"
VIAddVersionKey /LANG=1033 "ProductVersion" "1.0.0"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright Luke McLaughlin"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
Section "Install"
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "..\release\win-unpacked\*.*"
  CreateDirectory "$SMPROGRAMS\Alembic"
  CreateShortCut "$SMPROGRAMS\Alembic\Alembic.lnk" "$INSTDIR\Alembic.exe"
  CreateShortCut "$DESKTOP\Alembic.lnk" "$INSTDIR\Alembic.exe"
  WriteUninstaller "$INSTDIR\Uninstall Alembic.exe"
  WriteRegStr HKCU "Software\Luke McLaughlin\Alembic" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Alembic"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "1.0.0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Luke McLaughlin"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\Alembic.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall Alembic.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall Alembic.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd
Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\Alembic.lnk"
  Delete "$SMPROGRAMS\Alembic\Alembic.lnk"
  RMDir "$SMPROGRAMS\Alembic"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "Software\Luke McLaughlin\Alembic"
  !include "uninstall-files.nsh"
  Delete "$INSTDIR\Uninstall Alembic.exe"
  RMDir "$INSTDIR"
SectionEnd
