; [WIN_INSTALLER]: the per-user installer beside the Windows zip, made by
; util/package.sh windows with makensis:
;   makensis -DVERSION=<v> -DSTAGE=<the zip's stage> -DFILES=<dir> -DOUT=<exe>
; An alpha ([ALPHA_BUILDS]) adds -DPRODUCT="Buildat Alpha" -DDATA_DIR=buildat-alpha:
; its name, directory, uninstall key, shortcuts and data are its own, so it
; sits beside a stable one and upgrades over the previous alpha.
; FILES holds install.nsh and remove.nsh, the stage's top-level entries
; (but user/ and cache/) as File and RMDir/Delete lines, so that an
; upgrade and the uninstall remove only what was installed.
; Installed to %LOCALAPPDATA%\Programs\Buildat, no admin; bin\installed
; makes that copy keep its data where the platform says (APPDATA and
; LOCALAPPDATA's buildat, src/boot/autodetect.cpp), so the uninstall
; leaves it. The prebuilt modules go into that cache. Not signed.
; simplified: a fixed directory, no page to choose one: the upgrade's
; removal is by top-level name, which in a directory of the user's own
; could name a folder of theirs.
Unicode true
SetCompressor /SOLID lzma
!ifndef PRODUCT
	!define PRODUCT "Buildat"
!endif
; autodetect.cpp's data_dir_name()
!ifndef DATA_DIR
	!define DATA_DIR "buildat"
!endif
Name "${PRODUCT} ${VERSION}"
OutFile "${OUT}"
RequestExecutionLevel user
; The logo ([WIN_RESOURCES]); the shortcut and DisplayIcon take the exe's
Icon "${__FILEDIR__}/../client/data/buildat.ico"
UninstallIcon "${__FILEDIR__}/../client/data/buildat.ico"
InstallDir "$LOCALAPPDATA\Programs\${PRODUCT}"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT}"

Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section
	; Over an older version: its files out first
	!include "${FILES}/remove.nsh"
	SetOutPath "$INSTDIR"
	!include "${FILES}/install.nsh"
	FileOpen $0 "$INSTDIR\bin\installed" w
	FileWrite $0 "Installed by the Buildat installer: data in APPDATA and LOCALAPPDATA$\r$\n"
	FileClose $0
	SetOutPath "$LOCALAPPDATA\${DATA_DIR}\cache\rccpp_build"
	File /r "${STAGE}/cache/rccpp_build/*"
	; The shortcut's working directory is the one last set
	SetOutPath "$INSTDIR\bin"
	CreateShortcut "$SMPROGRAMS\${PRODUCT}.lnk" "$INSTDIR\bin\buildat.exe"
	; The folder the log is in ([LOG_REACH]): a tester could not find it
	CreateShortcut "$SMPROGRAMS\${PRODUCT} logs.lnk" "$LOCALAPPDATA\${DATA_DIR}\cache"
	WriteUninstaller "$INSTDIR\uninstall.exe"
	WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${PRODUCT}"
	WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
	WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "Buildat"
	WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
	WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\bin\buildat.exe"
	WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
	WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
	WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
	WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
	!include "${FILES}/remove.nsh"
	Delete "$INSTDIR\uninstall.exe"
	RMDir "$INSTDIR"
	; The modules it put into the cache; the rest of the cache and the
	; user's directory stay
	RMDir /r "$LOCALAPPDATA\${DATA_DIR}\cache\rccpp_build"
	Delete "$SMPROGRAMS\${PRODUCT}.lnk"
	Delete "$SMPROGRAMS\${PRODUCT} logs.lnk"
	DeleteRegKey HKCU "${UNINST_KEY}"
SectionEnd
