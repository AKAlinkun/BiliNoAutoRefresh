TARGET := iphone:clang:latest:14.0
ARCHS  = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiliNoAutoRefresh

BiliNoAutoRefresh_FILES      = Tweak.x
BiliNoAutoRefresh_FRAMEWORKS = UIKit Foundation
BiliNoAutoRefresh_CFLAGS     = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
