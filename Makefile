TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariLinkRouter
SafariLinkRouter_FILES = Tweak.xm LRCore.m
SafariLinkRouter_FRAMEWORKS = UIKit Foundation WebKit
SafariLinkRouter_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-objc-method-access -Wno-unused-function
SafariLinkRouter_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
