.PHONY: clean get-whl install-whl clean-whl build-mac-app pyinstaller build-dmg compile-mo codesign-windows needs-version

ifeq ($(OS),Windows_NT)
    OSNAME := WIN32
else
    OSNAME := $(shell uname -s)
endif

guard-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "Environment variable $* not set"; \
		exit 1; \
	fi

needs-version:
	$(eval KOLIBRI_VERSION ?= $(shell python3 -c "import os; import sys; sys.path = [os.path.abspath('kolibri')] + sys.path; from pkginfo import Installed; print(Installed('kolibri').version)"))
	$(eval APP_VERSION ?= $(shell python3 read_version.py))

clean:
	rm -rf build dist

clean-whl:
	rm -rf whl
	mkdir whl

install-whl:
	rm -rf kolibri
	pip3 install ${whl} -t kolibri/
	# Read SQLAlchemy version from the unpacked whl file to avoid hard coding.
	# Manually install the sqlalchemy version
	@version=$$(grep -Eo '__version__ = "([0-9]+\.[0-9]+\.[0-9]+)"' kolibri/kolibri/dist/sqlalchemy/__init__.py | grep -Eo "([0-9]+\.[0-9]+\.[0-9]+)"); \
	pip3 install sqlalchemy==$$version --no-binary :all:
	# Delete sqlalchemy from the dist folder
	rm -rf kolibri/kolibri/dist/sqlalchemy
	rm -rf kolibri/kolibri/dist/SQLAlchemy*
	# This doesn't exist in 0.15, so don't error if it doesn't exist.
	echo "3.3.1" > kolibri/kolibri/dist/importlib_resources/version.txt || true

get-whl: clean-whl
# The eval and shell commands here are evaluated when the recipe is parsed, so we put the cleanup
# into a prerequisite make step, in order to ensure they happen prior to the download.
	$(eval DLFILE = $(shell wget --content-disposition -P whl/ "${whl}" 2>&1 | grep "Saving to: " | sed 's/Saving to: ‘//' | sed 's/’//'))
	$(eval WHLFILE = $(shell echo "${DLFILE}" | sed "s/\?.*//"))
	[ "${DLFILE}" = "${WHLFILE}" ] || mv "${DLFILE}" "${WHLFILE}"
	$(MAKE) install-whl whl="${WHLFILE}"

dependencies:
	PYINSTALLER_COMPILE_BOOTLOADER=1 pip3 install -r build_requires.txt --no-binary pyinstaller
	python3 -c "import PyInstaller; import os; os.truncate(os.path.join(PyInstaller.__path__[0], 'hooks', 'rthooks', 'pyi_rth_django.py'), 0)"

build-mac-app:
	$(eval LIBPYTHON_FOLDER = $(shell python3 -c 'from distutils.sysconfig import get_config_var; print(get_config_var("LIBDIR"))'))
	test -f ${LIBPYTHON_FOLDER}/libpython3.10.dylib || ln -s ${LIBPYTHON_FOLDER}/libpython3.10m.dylib ${LIBPYTHON_FOLDER}/libpython3.10.dylib
	$(MAKE) pyinstaller

pyinstaller: clean
	mkdir -p logs
	pip3 install .
	python3 -OO -m PyInstaller kolibri.spec

build-dmg: needs-version
	python3 -m dmgbuild -s build_config/dmgbuild_settings.py "Kolibri ${KOLIBRI_VERSION}-${APP_VERSION}" dist/kolibri-${KOLIBRI_VERSION}-${APP_VERSION}.dmg

compile-mo:
	find src/kolibri_app/locales -name LC_MESSAGES -exec msgfmt {}/wxapp.po -o {}/wxapp.mo \;

codesign-windows:
	$(MAKE) guard-WIN_CODESIGN_PFX
	$(MAKE) guard-WIN_CODESIGN_PWD
	$(MAKE) guard-WIN_CODESIGN_CERT
	C:\Program Files (x86)\Windows Kits\8.1\bin\x64\signtool.exe sign /f ${WIN_CODESIGN_PFX} /p ${WIN_CODESIGN_PWD} /ac ${WIN_CODESIGN_CERT} /tr http://timestamp.ssl.trustwave.com /td SHA256 /fd SHA256 dist/kolibri-${KOLIBRI_VERSION}-${APP_VERSION}.exe

.PHONY: codesign-mac-app
codesign-mac-app:
	$(MAKE) guard-MAC_CODESIGN_IDENTITY
# Mac App Code Signing
# CODESIGN should start with "Developer ID Application: ..."
	xattr -cr dist/Kolibri.app
	codesign \
		--sign "Developer ID Application: $(MAC_CODESIGN_IDENTITY)" \
		--verbose=3 \
		--deep \
		--timestamp \
		--force \
		--strict \
		--entitlements build_config/entitlements.plist \
		-o runtime \
		dist/Kolibri.app
	codesign --display --verbose=3 --entitlements :- dist/Kolibri.app
	codesign --verify --verbose=3 --deep --strict=all dist/Kolibri.app

.PHONY: codesign-dmg
codesign-dmg: needs-version
	$(MAKE) guard-MAC_CODESIGN_IDENTITY
	xattr -cr dist/kolibri-${KOLIBRI_VERSION}-${APP_VERSION}.dmg
	codesign \
		--sign "Developer ID Application: $(MAC_CODESIGN_IDENTITY)" \
		--verbose=3 \
		--deep \
		--timestamp \
		--force \
		--strict \
		--entitlements build_config/entitlements.plist \
		-o runtime \
		dist/kolibri-${KOLIBRI_VERSION}-${APP_VERSION}.dmg

.PHONY: notarize-dmg
notarize-dmg: needs-version
	$(MAKE) guard-MAC_NOTARIZE_USERNAME
	$(MAKE) guard-MAC_NOTARIZE_PASSWORD
	./notarize-dmg.sh "./dist/kolibri-${KOLIBRI_VERSION}-${APP_VERSION}.dmg"
