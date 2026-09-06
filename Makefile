ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME=rootless
else ifeq ($(ROOTHIDE),1)
THEOS_PACKAGE_SCHEME=roothide
endif

DEBUG=0
FINALPACKAGE=1
ARCHS = arm64
PACKAGE_VERSION = 5.2.2
TARGET := iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTLite
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation SystemConfiguration Security AVFoundation CoreMedia Photos
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DTWEAK_VERSION=$(PACKAGE_VERSION) -Wno-error=misleading-indentation -Wno-error=format-extra-args -Wno-error=deprecated-declarations -Wno-deprecated-declarations
$(TWEAK_NAME)_FILES = $(wildcard *.x Utils/*.m)

include $(THEOS_MAKE_PATH)/tweak.mk
