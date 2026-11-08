# TweakSection — groups every tweak's settings pane under a single "Tweaks" entry
# in the iOS 6 Settings root list.
#
# Tested on: iPhone 4S (iPhone4,1), iOS 6.1.3 (10B329), ARMv7

export ARCHS = armv7
export TARGET = iphone:clang:6.1:6.0
export DEBUG = 0
# Can be overridden from the environment: THEOS_DEVICE_IP=192.168.x.x make install
export THEOS_DEVICE_IP ?= 192.168.31.179

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TweakSection

TweakSection_FILES = Tweak.x
TweakSection_CFLAGS = -fobjc-arc
TweakSection_LIBRARIES = substrate
TweakSection_LDFLAGS = -framework UIKit -framework Foundation -framework CoreGraphics -framework Preferences

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Preferences 2>/dev/null; true"
