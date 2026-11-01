#pragma once
#import <Foundation/Foundation.h>
#include <cstddef>
#include <cstdint>

// The custom-menu feature: BG3's Video options, for features that add or
// change options. It is enabled by the features that require it. They register
// from their install; custom-menu patches the Video options manager's Init and
// ApplyCombo at its activation, after them, before BG3 builds the menu.
//
// Every call below uses BG3's observed ARM64 ABI for its option items and must
// run on the thread BG3 builds and updates the menu on (from a callback).

// A localized text: BG3's ls::TranslatedString.
struct BG3MFXMenuText { uint32_t storage[4] = {}; bool constructed = false; };
// Makes `text` from a translation handle and its English literal; NO when BG3's
// translation repository is not ready or the text does not resolve to it.
BOOL BG3MFXMenuMakeText(BG3MFXMenuText &text, const char *identifier, const char *literal);
void BG3MFXMenuDestroyText(BG3MFXMenuText &text);

// Called after BG3 builds the Video options (which contain the Upscaling
// Type combo), in registration order, with the options manager.
void BG3MFXMenuOnBuilt(void (*built)(void *manager));
// Wraps the manager's ApplyCombo, which runs for each combo on Apply and when
// Options closes. `next` is the rest of the chain, BG3's own last.
using BG3MFXMenuApply = void (*)(void *manager, const void *item);
void BG3MFXMenuWrapApplyCombo(void (*wrapper)(void *manager, const void *item, BG3MFXMenuApply next));
// The Video options manager since it was last built, or null before.
void *BG3MFXMenuManager(void);
// Whether BG3 has built any options (Video or not) since launch. Any thread.
bool BG3MFXMenuOptionsBuilt(void);
// Whether custom-menu patched the menu (false outside BG3, in test harnesses).
bool BG3MFXMenuActive(void);
// A menu problem: reported, and shown to the player once. BG3's own options
// keep working.
void BG3MFXMenuProblem(NSString *reason);

// The manager's items.
size_t BG3MFXMenuItemCount(void *manager);
void *BG3MFXMenuItem(void *manager, size_t index);
uint8_t BG3MFXMenuItemType(void *item);  // 3 for a combo
uint16_t BG3MFXMenuItemID(void *item);
// The first item with `id` (and `type`, unless it is negative), or null.
void *BG3MFXMenuFind(void *manager, int type, uint16_t id);
// Moves the manager's last item, just added, to `index`.
void BG3MFXMenuMoveLast(void *manager, size_t index);
// Enables or dims an item, notifying its observers as RefreshUIAntiAliasing does.
void BG3MFXMenuSetEnabled(void *item, bool enabled);

// Option callbacks are BG3 Functions: Call(storage, item), with the storage
// inline in the item. The storage captures the manager.
using BG3MFXMenuCallback = void (*)(void *storage, const void *item);
BG3MFXMenuCallback BG3MFXMenuSelectionCallback(void *item);
void BG3MFXMenuSetSelectionCallback(void *item, BG3MFXMenuCallback callback);
void *BG3MFXMenuCallbackStorage(void *item);
void *BG3MFXMenuStorageManager(void *storage);
void *BG3MFXMenuItemManager(void *item);  // the manager the item's callback captured

// Tick boxes and sliders, added last; `changed` replaces only the Call of the
// Function BG3 installs (its Copy/MoveDestroy and captured manager stay).
void *BG3MFXMenuAddTickBox(void *manager, uint16_t id, const BG3MFXMenuText &name, const BG3MFXMenuText &description,
                           bool value, BG3MFXMenuCallback changed);
bool BG3MFXMenuTickBoxValue(const void *item);
void *BG3MFXMenuAddSlider(void *manager, uint16_t id, const BG3MFXMenuText &name, const BG3MFXMenuText &description,
                          float value, float lowest, float highest, BG3MFXMenuCallback changed);
float BG3MFXMenuSliderValue(const void *item);
// Shows `value` on a slider, notifying its value observers.
void BG3MFXMenuShowSliderValue(void *item, float value);

// Combos: their items' values and labels, and the selection.
NSArray<NSNumber *> *BG3MFXMenuComboValues(void *combo);
NSString *BG3MFXMenuComboLabel(void *combo, size_t index);
void BG3MFXMenuAppendComboValue(void *combo, int value, const BG3MFXMenuText &name, const BG3MFXMenuText &description);
// After changing a combo's items, as RefreshUIUpscaleMode does.
void BG3MFXMenuComboItemsChanged(void *combo);
int BG3MFXMenuComboSelection(const void *combo);
void BG3MFXMenuSetComboSelection(void *combo, int value);  // without notifying
// Sets the selection and notifies its observers, without BG3's callback.
void BG3MFXMenuShowComboSelection(void *combo, int value);
// Selects through BG3's own callback, then shows it.
void BG3MFXMenuSelectCombo(void *combo, int value);
