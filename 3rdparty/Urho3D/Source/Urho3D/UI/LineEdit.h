//
// Copyright (c) 2008-2017 the Urho3D project.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#pragma once

#include "../UI/BorderImage.h"

namespace Urho3D
{

class Font;
class Text;

/// Single-line text editor %UI element.
class URHO3D_API LineEdit : public BorderImage
{
    URHO3D_OBJECT(LineEdit, BorderImage);

public:
    /// Construct.
    LineEdit(Context* context);
    /// Destruct.
    virtual ~LineEdit();
    /// Register object factory.
    static void RegisterObject(Context* context);

    /// Apply attribute changes that can not be applied immediately.
    virtual void ApplyAttributes();
    /// Perform UI element update.
    virtual void Update(float timeStep);
    /// React to mouse click begin.
    virtual void OnClickBegin
        (const IntVector2& position, const IntVector2& screenPosition, int button, int buttons, int qualifiers, Cursor* cursor);
    /// React to mouse doubleclick.
    virtual void OnDoubleClick
        (const IntVector2& position, const IntVector2& screenPosition, int button, int buttons, int qualifiers, Cursor* cursor);
    /// React to mouse drag begin.
    virtual void
        OnDragBegin(const IntVector2& position, const IntVector2& screenPosition, int buttons, int qualifiers, Cursor* cursor);
    /// React to mouse drag motion.
    virtual void OnDragMove
        (const IntVector2& position, const IntVector2& screenPosition, const IntVector2& deltaPos, int buttons, int qualifiers,
            Cursor* cursor);
    /// React to drag and drop test. Return true to signal that the drop is acceptable.
    virtual bool OnDragDropTest(UIElement* source);
    /// React to drag and drop finish. Return true to signal that the drop was accepted.
    virtual bool OnDragDropFinish(UIElement* source);
    /// React to a key press.
    virtual void OnKey(int key, int buttons, int qualifiers);
    /// React to text input event.
    virtual void OnTextInput(const String& text);
    /// buildat: react to the mouse wheel; a multi-line edit scrolls its text.
    virtual void OnWheel(int delta, int buttons, int qualifiers);

    /// Set text.
    void SetText(const String& text);
    /// buildat [TEXT_UNDO]: set the text as the user's own edit, grouped with typing as an undo step (the web page's sync).
    void SetTextAsTyped(const String& text);
    /// buildat [TEXT_UNDO]: undo the last step of editing.
    void Undo();
    /// buildat [TEXT_UNDO]: redo the last undone step.
    void Redo();
    /// Set cursor position.
    void SetCursorPosition(unsigned position);
    /// Set cursor blink rate. 0 disables blinking.
    void SetCursorBlinkRate(float rate);
    /// Set maximum text length. 0 for unlimited.
    void SetMaxLength(unsigned length);
    /// Set echo character for password entry and such. 0 (default) shows the actual text.
    void SetEchoCharacter(unsigned c);
    /// Set whether can move cursor with arrows or mouse, default true.
    void SetCursorMovable(bool enable);
    /// Set whether selections are allowed, default true.
    void SetTextSelectable(bool enable);
    /// Set whether copy-paste operations are allowed, default true.
    void SetTextCopyable(bool enable);
    /// buildat [HEARTH_MVP]: set multi-line: Enter breaks the line, Ctrl+Enter finishes, the text wraps to the width and Up, Down, Home and End move by rows.
    void SetMultiLine(bool enable);

    /// Return text.
    const String& GetText() const { return line_; }

    /// Return cursor position.
    unsigned GetCursorPosition() const { return cursorPosition_; }

    /// Return cursor blink rate.
    float GetCursorBlinkRate() const { return cursorBlinkRate_; }

    /// Return maximum text length.
    unsigned GetMaxLength() const { return maxLength_; }

    /// Return echo character.
    unsigned GetEchoCharacter() const { return echoCharacter_; }

    /// Return whether can move cursor with arrows or mouse.
    bool IsCursorMovable() const { return cursorMovable_; }

    /// Return whether selections are allowed.
    bool IsTextSelectable() const { return textSelectable_; }

    /// Return whether copy-paste operations are allowed.
    bool IsTextCopyable() const { return textCopyable_; }

    /// buildat: return whether multi-line.
    bool IsMultiLine() const { return multiLine_; }
    /// buildat: return whether a wheel of delta would scroll the text: a
    /// multi-line edit with more to show that way.
    bool WheelScrolls(int delta) const;

    /// Return text element.
    Text* GetTextElement() const { return text_; }

    /// Return cursor element.
    BorderImage* GetCursor() const { return cursor_; }

protected:
    /// Filter implicit attributes in serialization process.
    virtual bool FilterImplicitAttributes(XMLElement& dest) const;
    /// Update displayed text.
    void UpdateText();
    /// Update cursor position and restart cursor blinking. buildat: follow
    /// false keeps a multi-line edit's vertical scroll (a layout update,
    /// not the cursor moving, so the wheel's scroll stays).
    void UpdateCursor(bool follow = true);
    /// Return char index corresponding to position within element, or M_MAX_UNSIGNED if not found.
    unsigned GetCharIndex(const IntVector2& position);
    /// buildat [TEXT_KEYS]: select from start to end, the cursor at the end.
    void SelectRange(unsigned start, unsigned end);
    /// buildat: the character nearest a position in the text's own coordinates, on its row.
    unsigned GetCharIndexOnRow(const IntVector2& textPosition);

    /// Text element.
    SharedPtr<Text> text_;
    /// Cursor element.
    SharedPtr<BorderImage> cursor_;
    /// Text line.
    String line_;
    /// Last used text font.
    Font* lastFont_;
    /// Last used text size.
    int lastFontSize_;
    /// Text edit cursor position.
    unsigned cursorPosition_;
    /// Drag begin cursor position.
    unsigned dragBeginCursor_;
    /// buildat [TEXT_KEYS]: when the last double-click was (SDL ticks), for a triple-click; 0 none.
    unsigned lastDoubleClick_;
    /// Cursor blink rate.
    float cursorBlinkRate_;
    /// Cursor blink timer.
    float cursorBlinkTimer_;
    /// Maximum text length.
    unsigned maxLength_;
    /// Echo character.
    unsigned echoCharacter_;
    /// Cursor movable flag.
    bool cursorMovable_;
    /// Text selectable flag.
    bool textSelectable_;
    /// Copy-paste enable flag.
    bool textCopyable_;
    /// buildat: multi-line flag.
    bool multiLine_;
    /// buildat [TEXT_UNDO]: the text, cursor and selection of an undo step.
    struct EditState
    {
        String text_;
        unsigned cursor_;
        unsigned selectionStart_;
        unsigned selectionLength_;
    };
    /// buildat [TEXT_UNDO]: the state now.
    EditState GetEditState() const;
    /// buildat [TEXT_UNDO]: go back to a state.
    void RestoreEditState(const EditState& state);
    /// buildat [TEXT_UNDO]: before an edit of a kind, keep the state as a step unless it continues the last one.
    void Snapshot(int kind, bool wordStart = false);
    /// buildat [TEXT_UNDO]: the undo and redo steps.
    Vector<EditState> undo_;
    Vector<EditState> redo_;
    /// buildat [TEXT_UNDO]: the last edit's kind (-1 none) and time (SDL ticks).
    int lastEditKind_;
    unsigned lastEditTime_;
    /// buildat [HEARTH_PAGE_KEYS]: the x on its wrapped row that a run of Up, Down, Page Up and Page Down keeps to, and the cursor position the last of them left (M_MAX_UNSIGNED none: the next starts a run).
    int goalX_;
    unsigned goalAt_;

private:
    /// Handle being focused.
    void HandleFocused(StringHash eventType, VariantMap& eventData);
    /// Handle being defocused.
    void HandleDefocused(StringHash eventType, VariantMap& eventData);
    /// Handle the element layout having been updated.
    void HandleLayoutUpdated(StringHash eventType, VariantMap& eventData);
};

}
