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

#include "../Precompiled.h"

#include "../Core/Context.h"
#include "../Input/Input.h"
#include "../UI/LineEdit.h"
#include "../UI/Text.h"
#include "../UI/UI.h"
#include "../UI/UIEvents.h"

#include "../DebugNew.h"

#include <SDL/SDL.h>

namespace Urho3D
{

StringHash VAR_DRAGDROPCONTENT("DragDropContent");

extern const char* UI_CATEGORY;

LineEdit::LineEdit(Context* context) :
    BorderImage(context),
    lastFont_(0),
    lastFontSize_(0),
    cursorPosition_(0),
    dragBeginCursor_(M_MAX_UNSIGNED),
    lastDoubleClick_(0),
    lastEditKind_(-1),
    lastEditTime_(0),
    cursorBlinkRate_(1.0f),
    cursorBlinkTimer_(0.0f),
    maxLength_(0),
    echoCharacter_(0),
    cursorMovable_(true),
    textSelectable_(true),
    textCopyable_(true),
    multiLine_(false)
{
    clipChildren_ = true;
    SetEnabled(true);
    focusMode_ = FM_FOCUSABLE_DEFOCUSABLE;

    text_ = CreateChild<Text>("LE_Text");
    text_->SetInternal(true);
    cursor_ = CreateChild<BorderImage>("LE_Cursor");
    cursor_->SetInternal(true);
    cursor_->SetPriority(1); // Show over text

    SubscribeToEvent(this, E_FOCUSED, URHO3D_HANDLER(LineEdit, HandleFocused));
    SubscribeToEvent(this, E_DEFOCUSED, URHO3D_HANDLER(LineEdit, HandleDefocused));
    SubscribeToEvent(this, E_LAYOUTUPDATED, URHO3D_HANDLER(LineEdit, HandleLayoutUpdated));
}

LineEdit::~LineEdit()
{
}

void LineEdit::RegisterObject(Context* context)
{
    context->RegisterFactory<LineEdit>(UI_CATEGORY);

    URHO3D_COPY_BASE_ATTRIBUTES(BorderImage);
    URHO3D_UPDATE_ATTRIBUTE_DEFAULT_VALUE("Clip Children", true);
    URHO3D_UPDATE_ATTRIBUTE_DEFAULT_VALUE("Is Enabled", true);
    URHO3D_UPDATE_ATTRIBUTE_DEFAULT_VALUE("Focus Mode", FM_FOCUSABLE_DEFOCUSABLE);
    URHO3D_ACCESSOR_ATTRIBUTE("Max Length", GetMaxLength, SetMaxLength, unsigned, 0, AM_FILE);
    URHO3D_ACCESSOR_ATTRIBUTE("Is Cursor Movable", IsCursorMovable, SetCursorMovable, bool, true, AM_FILE);
    URHO3D_ACCESSOR_ATTRIBUTE("Is Text Selectable", IsTextSelectable, SetTextSelectable, bool, true, AM_FILE);
    URHO3D_ACCESSOR_ATTRIBUTE("Is Text Copyable", IsTextCopyable, SetTextCopyable, bool, true, AM_FILE);
    URHO3D_ACCESSOR_ATTRIBUTE("Cursor Blink Rate", GetCursorBlinkRate, SetCursorBlinkRate, float, 1.0f, AM_FILE);
    URHO3D_ATTRIBUTE("Echo Character", int, echoCharacter_, 0, AM_FILE);
}

void LineEdit::ApplyAttributes()
{
    BorderImage::ApplyAttributes();

    // Set the text's position to match clipping and indent width, so that text left edge is not left partially hidden
    text_->SetPosition(GetIndentWidth() + clipBorder_.left_, clipBorder_.top_);

    // Sync the text line
    line_ = text_->GetText();
}

void LineEdit::Update(float timeStep)
{
    if (cursorBlinkRate_ > 0.0f)
        cursorBlinkTimer_ = fmodf(cursorBlinkTimer_ + cursorBlinkRate_ * timeStep, 1.0f);

    // Update cursor position if font has changed
    if (text_->GetFont() != lastFont_ || text_->GetFontSize() != lastFontSize_)
    {
        lastFont_ = text_->GetFont();
        lastFontSize_ = text_->GetFontSize();
        UpdateCursor();
    }

    bool cursorVisible = HasFocus() ? cursorBlinkTimer_ < 0.5f : false;
    cursor_->SetVisible(cursorVisible);
}

// buildat [TEXT_KEYS]: a word is readline's -- letters, digits and _, any
// non-ASCII character a letter, so a Finnish word is one. A move or a delete
// skips what is not a word, then the word; a line break is a step of its own,
// taken with the spaces beside it.
static bool IsWordChar(unsigned c)
{
    return c >= 128 || c == '_' || isalnum((int)c);
}

static PODVector<unsigned> Chars(const String& s)
{
    PODVector<unsigned> cs;
    for (unsigned i = 0; i < s.Length();)
        cs.Push(s.NextUTF8Char(i));
    return cs;
}

static bool IsBlank(unsigned c)
{
    return c == ' ' || c == '\t';
}

static unsigned WordLeft(const PODVector<unsigned>& cs, unsigned pos)
{
    if (pos > 0 && cs[pos - 1] == '\n')
    {
        for (--pos; pos > 0 && IsBlank(cs[pos - 1]); --pos);
        return pos;
    }
    while (pos > 0 && !IsWordChar(cs[pos - 1]) && cs[pos - 1] != '\n')
        --pos;
    while (pos > 0 && IsWordChar(cs[pos - 1]))
        --pos;
    return pos;
}

static unsigned WordRight(const PODVector<unsigned>& cs, unsigned pos)
{
    if (pos < cs.Size() && cs[pos] == '\n')
    {
        for (++pos; pos < cs.Size() && IsBlank(cs[pos]); ++pos);
        return pos;
    }
    while (pos < cs.Size() && !IsWordChar(cs[pos]) && cs[pos] != '\n')
        ++pos;
    while (pos < cs.Size() && IsWordChar(cs[pos]))
        ++pos;
    return pos;
}

// buildat [TEXT_UNDO]: what starts an undo step. Typing, and erasing a
// character at a time, go on one step until a pause of a second, an edit of
// another kind or, typing, a word begun; anything else is a step of its own.
static const int EDIT_STEP = 0, EDIT_TYPE = 1, EDIT_ERASE = 2;
// simplified: whole-text snapshots, capped by count and size with the oldest
// dropped; a diff per step is the upgrade if a long text's memory shows up
static const unsigned UNDO_MAX_STEPS = 100, UNDO_MAX_BYTES = 1024 * 1024;

LineEdit::EditState LineEdit::GetEditState() const
{
    EditState s;
    s.text_ = line_;
    s.cursor_ = cursorPosition_;
    s.selectionStart_ = text_->GetSelectionStart();
    s.selectionLength_ = text_->GetSelectionLength();
    return s;
}

void LineEdit::RestoreEditState(const EditState& s)
{
    line_ = s.text_;
    cursorPosition_ = Min(s.cursor_, line_.LengthUTF8());
    UpdateText();
    if (s.selectionLength_)
        text_->SetSelection(s.selectionStart_, s.selectionLength_);
    else
        text_->ClearSelection();
    UpdateCursor();
    lastEditKind_ = -1;
}

void LineEdit::Snapshot(int kind, bool wordStart)
{
    unsigned now = SDL_GetTicks();
    bool goesOn = kind != EDIT_STEP && kind == lastEditKind_ && now - lastEditTime_ < 1000 && !wordStart;
    lastEditKind_ = kind;
    lastEditTime_ = now;
    redo_.Clear();
    if (goesOn)
        return;
    undo_.Push(GetEditState());
    unsigned bytes = 0;
    for (unsigned i = 0; i < undo_.Size(); ++i)
        bytes += undo_[i].text_.Length();
    while (undo_.Size() > 1 && (undo_.Size() > UNDO_MAX_STEPS || bytes > UNDO_MAX_BYTES))
    {
        bytes -= undo_[0].text_.Length();
        undo_.Erase(0);
    }
}

void LineEdit::Undo()
{
    if (!editable_ || undo_.Empty())
        return;
    redo_.Push(GetEditState());
    EditState s = undo_.Back();
    undo_.Pop();
    RestoreEditState(s);
}

void LineEdit::Redo()
{
    if (!editable_ || redo_.Empty())
        return;
    undo_.Push(GetEditState());
    EditState s = redo_.Back();
    redo_.Pop();
    RestoreEditState(s);
}

void LineEdit::SelectRange(unsigned start, unsigned end)
{
    text_->SetSelection(start, end - start);
    dragBeginCursor_ = start;
    cursorPosition_ = end;
    UpdateCursor();
}

void LineEdit::OnClickBegin(const IntVector2& position, const IntVector2& screenPosition, int button, int buttons, int qualifiers,
    Cursor* cursor)
{
    // buildat [TEXT_KEYS]: a third click within the double-click time selects
    // the whole text, or the line in a multi-line edit
    if (button == MOUSEB_LEFT && textSelectable_ && lastDoubleClick_ &&
        SDL_GetTicks() - lastDoubleClick_ < (unsigned)(GetSubsystem<UI>()->GetDoubleClickInterval() * 1000))
    {
        lastDoubleClick_ = 0;
        if (!multiLine_)
        {
            SelectRange(0, line_.LengthUTF8());
            return;
        }
        PODVector<unsigned> cs = Chars(line_);
        unsigned start = Min(cursorPosition_, cs.Size()), end = start;
        while (start > 0 && cs[start - 1] != '\n')
            --start;
        while (end < cs.Size() && cs[end] != '\n')
            ++end;
        SelectRange(start, end);
        return;
    }
    if (button == MOUSEB_LEFT && cursorMovable_)
    {
        unsigned pos = GetCharIndex(position);
        if (pos != M_MAX_UNSIGNED)
        {
            SetCursorPosition(pos);
            text_->ClearSelection();
        }
    }
}

void LineEdit::OnDoubleClick(const IntVector2& position, const IntVector2& screenPosition, int button, int buttons, int qualifiers,
    Cursor* cursor)
{
    // buildat [TEXT_KEYS]: the word under it, not the whole text
    if (button != MOUSEB_LEFT || !textSelectable_)
        return;
    lastDoubleClick_ = SDL_GetTicks();
    if (!lastDoubleClick_)
        lastDoubleClick_ = 1;
    PODVector<unsigned> cs = Chars(line_);
    unsigned pos = GetCharIndex(position);
    if (pos == M_MAX_UNSIGNED || cs.Empty())
        return;
    if (pos >= cs.Size())
        pos = cs.Size() - 1;
    unsigned start = pos, end = pos + 1;
    if (IsWordChar(cs[pos]))
    {
        while (start > 0 && IsWordChar(cs[start - 1]))
            --start;
        while (end < cs.Size() && IsWordChar(cs[end]))
            ++end;
    }
    SelectRange(start, end);
}

void LineEdit::OnDragBegin(const IntVector2& position, const IntVector2& screenPosition, int buttons, int qualifiers,
    Cursor* cursor)
{
    UIElement::OnDragBegin(position, screenPosition, buttons, qualifiers, cursor);

    dragBeginCursor_ = GetCharIndex(position);
}

void LineEdit::OnDragMove(const IntVector2& position, const IntVector2& screenPosition, const IntVector2& deltaPos, int buttons,
    int qualifiers, Cursor* cursor)
{
    if (cursorMovable_ && textSelectable_)
    {
        unsigned start = dragBeginCursor_;
        unsigned current = GetCharIndex(position);
        if (start != M_MAX_UNSIGNED && current != M_MAX_UNSIGNED)
        {
            if (start < current)
                text_->SetSelection(start, current - start);
            else
                text_->SetSelection(current, start - current);
            SetCursorPosition(current);
        }
    }
}

bool LineEdit::OnDragDropTest(UIElement* source)
{
    if (source && editable_)
    {
        if (source->GetVars().Contains(VAR_DRAGDROPCONTENT))
            return true;
        StringHash sourceType = source->GetType();
        return sourceType == LineEdit::GetTypeStatic() || sourceType == Text::GetTypeStatic();
    }

    return false;
}

bool LineEdit::OnDragDropFinish(UIElement* source)
{
    if (source && editable_)
    {
        // If the UI element in question has a drag-and-drop content string defined, use it instead of element text
        if (source->GetVars().Contains(VAR_DRAGDROPCONTENT))
        {
            SetText(source->GetVar(VAR_DRAGDROPCONTENT).GetString());
            return true;
        }

        StringHash sourceType = source->GetType();
        if (sourceType == LineEdit::GetTypeStatic())
        {
            LineEdit* sourceLineEdit = static_cast<LineEdit*>(source);
            SetText(sourceLineEdit->GetText());
            return true;
        }
        else if (sourceType == Text::GetTypeStatic())
        {
            Text* sourceText = static_cast<Text*>(source);
            SetText(sourceText->GetText());
            return true;
        }
    }

    return false;
}

void LineEdit::OnKey(int key, int buttons, int qualifiers)
{
#ifdef __EMSCRIPTEN__
    // buildat [WEB_KEYS]: in the browser, its own copy, cut and paste do
    // these through the page's textarea (src/client/app.cpp); doing them
    // here as well would paste twice
    if ((key == KEY_X || key == KEY_C || key == KEY_V) && (qualifiers & QUAL_CTRL))
        return;
    // buildat [TEXT_KEYS]: and the word keys and select all, which the
    // browser does in the textarea and the page does Alt+Backspace by the
    // same rule; done here too, a word would go twice. Undo is this field's
    // ([TEXT_UNDO]): the page keeps the browser's own from it.
    if ((qualifiers & (QUAL_CTRL | QUAL_ALT)) && (key == KEY_A || key == KEY_LEFT ||
        key == KEY_RIGHT || key == KEY_BACKSPACE || key == KEY_DELETE))
        return;
#endif
    bool changed = false;
    bool cursorMoved = false;
    // buildat [TEXT_KEYS]: Home and End are the ends; Ctrl with an arrow a word
    bool ends = false;

    // buildat [HEARTH_MVP]: a multi-line edit moves by rows, and Enter is a
    // line break; Ctrl+Enter is what finishes it
    if (multiLine_)
    {
        IntVector2 at = VectorRoundToInt(text_->GetCharPosition(cursorPosition_));
        int row = text_->GetRowHeight();
        unsigned target = M_MAX_UNSIGNED;
        if (key == KEY_UP)
            target = at.y_ < row ? 0 : GetCharIndexOnRow(IntVector2(at.x_, at.y_ - row));
        else if (key == KEY_DOWN)
            target = GetCharIndexOnRow(IntVector2(at.x_, at.y_ + row));
        // buildat [HEARTH_PAGE_KEYS]: Page Up and Down move by the rows
        // shown less two (one in a field of four or fewer), so that pressing
        // again misses no line as the view follows the cursor. Shown is
        // what its clipping parents and the screen leave of the field: one
        // that grows with its text scrolls in its page (Hearth's)
        else if (key == KEY_PAGEUP || key == KEY_PAGEDOWN)
        {
            int top = GetScreenPosition().y_ + clipBorder_.top_;
            int bottom = GetScreenPosition().y_ + GetHeight() - clipBorder_.bottom_;
            for (UIElement* p = GetParent(); p; p = p->GetParent())
            {
                if (!p->GetClipChildren() && p->GetParent())
                    continue;
                int y = p->GetScreenPosition().y_;
                top = Max(top, y + p->GetClipBorder().top_);
                bottom = Min(bottom, y + p->GetHeight() - p->GetClipBorder().bottom_);
            }
            int shown = (bottom - top) / Max(row, 1);
            int page = Max(shown - (shown > 4 ? 2 : 1), 1) * row;
            if (key == KEY_PAGEUP)
                target = at.y_ < row ? 0 : GetCharIndexOnRow(IntVector2(at.x_, Max(at.y_ - page, 0)));
            else
                target = GetCharIndexOnRow(IntVector2(at.x_, at.y_ + page));
        }
        else if (key == KEY_HOME && !(qualifiers & QUAL_CTRL))
            target = GetCharIndexOnRow(IntVector2(0, at.y_));
        else if (key == KEY_END && !(qualifiers & QUAL_CTRL))
            target = GetCharIndexOnRow(IntVector2(M_MAX_INT / 2, at.y_));
        else if ((key == KEY_RETURN || key == KEY_RETURN2 || key == KEY_KP_ENTER) && !(qualifiers & QUAL_CTRL))
        {
            OnTextInput("\n");
            return;
        }
        if (target != M_MAX_UNSIGNED)
        {
            if (!cursorMovable_)
                return;
            if (textSelectable_ && qualifiers & QUAL_SHIFT)
            {
                if (!text_->GetSelectionLength())
                    dragBeginCursor_ = cursorPosition_;
                unsigned start = dragBeginCursor_;
                if (start < target)
                    text_->SetSelection(start, target - start);
                else
                    text_->SetSelection(target, start - target);
            }
            else
                text_->ClearSelection();
            cursorPosition_ = target;
            UpdateCursor();
            return;
        }
    }

    switch (key)
    {
    case KEY_X:
    case KEY_C:
        if (textCopyable_ && qualifiers & QUAL_CTRL)
        {
            unsigned start = text_->GetSelectionStart();
            unsigned length = text_->GetSelectionLength();

            if (text_->GetSelectionLength())
                GetSubsystem<UI>()->SetClipboardText(line_.SubstringUTF8(start, length));

            if (key == KEY_X && editable_)
            {
                if (length)
                    Snapshot(EDIT_STEP);
                if (start + length < line_.LengthUTF8())
                    line_ = line_.SubstringUTF8(0, start) + line_.SubstringUTF8(start + length);
                else
                    line_ = line_.SubstringUTF8(0, start);
                text_->ClearSelection();
                cursorPosition_ = start;
                changed = true;
            }
        }
        break;

    case KEY_V:
        if (editable_ && textCopyable_ && qualifiers & QUAL_CTRL)
        {
            const String& clipBoard = GetSubsystem<UI>()->GetClipboardText();
            if (!clipBoard.Empty())
            {
                Snapshot(EDIT_STEP);
                // Remove selected text first
                if (text_->GetSelectionLength() > 0)
                {
                    unsigned start = text_->GetSelectionStart();
                    unsigned length = text_->GetSelectionLength();
                    if (start + length < line_.LengthUTF8())
                        line_ = line_.SubstringUTF8(0, start) + line_.SubstringUTF8(start + length);
                    else
                        line_ = line_.SubstringUTF8(0, start);
                    text_->ClearSelection();
                    cursorPosition_ = start;
                }
                if (cursorPosition_ < line_.LengthUTF8())
                    line_ = line_.SubstringUTF8(0, cursorPosition_) + clipBoard + line_.SubstringUTF8(cursorPosition_);
                else
                    line_ += clipBoard;
                cursorPosition_ += clipBoard.LengthUTF8();
                changed = true;
            }
        }
        break;

    // buildat [TEXT_UNDO]: Ctrl+Z undoes, Ctrl+Y and Ctrl+Shift+Z redo
    case KEY_Z:
        if (qualifiers & QUAL_CTRL)
        {
            if (qualifiers & QUAL_SHIFT)
                Redo();
            else
                Undo();
        }
        return;

    case KEY_Y:
        if (qualifiers & QUAL_CTRL)
            Redo();
        return;

    // buildat [TEXT_KEYS]: Ctrl+A selects all
    case KEY_A:
        if (textSelectable_ && qualifiers & QUAL_CTRL && line_.Length())
            SelectRange(0, line_.LengthUTF8());
        return;

    case KEY_HOME:
        ends = true;
        // Fallthru

    case KEY_LEFT:
        if (cursorMovable_ && cursorPosition_ > 0)
        {
            if (textSelectable_ && qualifiers & QUAL_SHIFT && !text_->GetSelectionLength())
                dragBeginCursor_ = cursorPosition_;

            if (ends)
                cursorPosition_ = 0;
            else if (qualifiers & QUAL_CTRL)
                cursorPosition_ = WordLeft(Chars(line_), cursorPosition_);
            else if (text_->GetSelectionLength() && !(qualifiers & QUAL_SHIFT))
                cursorPosition_ = text_->GetSelectionStart();
            else
                --cursorPosition_;
            cursorMoved = true;

            if (textSelectable_ && qualifiers & QUAL_SHIFT)
            {
                unsigned start = dragBeginCursor_;
                unsigned current = cursorPosition_;
                if (start < current)
                    text_->SetSelection(start, current - start);
                else
                    text_->SetSelection(current, start - current);
            }
        }
        if (!(qualifiers & QUAL_SHIFT))
            text_->ClearSelection();
        break;

    case KEY_END:
        ends = true;
        // Fallthru

    case KEY_RIGHT:
        if (cursorMovable_ && cursorPosition_ < line_.LengthUTF8())
        {
            if (textSelectable_ && qualifiers & QUAL_SHIFT && !text_->GetSelectionLength())
                dragBeginCursor_ = cursorPosition_;

            if (ends)
                cursorPosition_ = line_.LengthUTF8();
            else if (qualifiers & QUAL_CTRL)
                cursorPosition_ = WordRight(Chars(line_), cursorPosition_);
            else if (text_->GetSelectionLength() && !(qualifiers & QUAL_SHIFT))
                cursorPosition_ = text_->GetSelectionStart() + text_->GetSelectionLength();
            else
                ++cursorPosition_;
            cursorMoved = true;

            if (textSelectable_ && qualifiers & QUAL_SHIFT)
            {
                unsigned start = dragBeginCursor_;
                unsigned current = cursorPosition_;
                if (start < current)
                    text_->SetSelection(start, current - start);
                else
                    text_->SetSelection(current, start - current);
            }
        }
        if (!(qualifiers & QUAL_SHIFT))
            text_->ClearSelection();
        break;

    case KEY_DELETE:
        if (editable_)
        {
            if (!text_->GetSelectionLength())
            {
                // buildat [TEXT_KEYS]: Ctrl+Delete to the next word's end
                unsigned end = cursorPosition_ + 1;
                if (qualifiers & QUAL_CTRL)
                    end = WordRight(Chars(line_), cursorPosition_);
                if (cursorPosition_ < line_.LengthUTF8())
                {
                    Snapshot(qualifiers & QUAL_CTRL ? EDIT_STEP : EDIT_ERASE);
                    line_ = line_.SubstringUTF8(0, cursorPosition_) + line_.SubstringUTF8(end);
                    changed = true;
                }
            }
            else
            {
                // If a selection exists, erase it
                Snapshot(EDIT_STEP);
                unsigned start = text_->GetSelectionStart();
                unsigned length = text_->GetSelectionLength();
                if (start + length < line_.LengthUTF8())
                    line_ = line_.SubstringUTF8(0, start) + line_.SubstringUTF8(start + length);
                else
                    line_ = line_.SubstringUTF8(0, start);
                text_->ClearSelection();
                cursorPosition_ = start;
                changed = true;
            }
        }
        break;

    case KEY_UP:
    case KEY_DOWN:
    case KEY_PAGEUP:
    case KEY_PAGEDOWN:
        {
            using namespace UnhandledKey;

            VariantMap& eventData = GetEventDataMap();
            eventData[P_ELEMENT] = this;
            eventData[P_KEY] = key;
            eventData[P_BUTTONS] = buttons;
            eventData[P_QUALIFIERS] = qualifiers;
            SendEvent(E_UNHANDLEDKEY, eventData);
        }
        return;

    case KEY_BACKSPACE:
        if (editable_)
        {
            if (!text_->GetSelectionLength())
            {
                // buildat [TEXT_KEYS]: Alt+Backspace (readline's) and
                // Ctrl+Backspace back to the previous word's start
                if (line_.LengthUTF8() && cursorPosition_)
                {
                    unsigned start = cursorPosition_ - 1;
                    Snapshot(qualifiers & (QUAL_CTRL | QUAL_ALT) ? EDIT_STEP : EDIT_ERASE);
                    if (qualifiers & (QUAL_CTRL | QUAL_ALT))
                        start = WordLeft(Chars(line_), cursorPosition_);
                    line_ = line_.SubstringUTF8(0, start) + line_.SubstringUTF8(cursorPosition_);
                    cursorPosition_ = start;
                    changed = true;
                }
            }
            else
            {
                // If a selection exists, erase it
                Snapshot(EDIT_STEP);
                unsigned start = text_->GetSelectionStart();
                unsigned length = text_->GetSelectionLength();
                if (start + length < line_.LengthUTF8())
                    line_ = line_.SubstringUTF8(0, start) + line_.SubstringUTF8(start + length);
                else
                    line_ = line_.SubstringUTF8(0, start);
                text_->ClearSelection();
                cursorPosition_ = start;
                changed = true;
            }
        }
        break;

    case KEY_RETURN:
    case KEY_RETURN2:
    case KEY_KP_ENTER:
        {
            // If using the on-screen keyboard, defocus this element to hide it now
            if (GetSubsystem<UI>()->GetUseScreenKeyboard() && HasFocus())
                SetFocus(false);

            using namespace TextFinished;

            VariantMap& eventData = GetEventDataMap();
            eventData[P_ELEMENT] = this;
            eventData[P_TEXT] = line_;
            SendEvent(E_TEXTFINISHED, eventData);
            return;
        }

    default: break;
    }

    if (changed)
    {
        UpdateText();
        UpdateCursor();
    }
    else if (cursorMoved)
        UpdateCursor();
}

void LineEdit::OnTextInput(const String& text)
{
    if (!editable_)
        return;

    bool changed = false;

    // Send text entry as an event to allow changing it
    using namespace TextEntry;

    VariantMap& eventData = GetEventDataMap();
    eventData[P_ELEMENT] = this;
    eventData[P_TEXT] = text;
    SendEvent(E_TEXTENTRY, eventData);

    const String newText = eventData[P_TEXT].GetString().SubstringUTF8(0);
    if (!newText.Empty() && (!maxLength_ || line_.LengthUTF8() + newText.LengthUTF8() <= maxLength_))
    {
        // buildat [TEXT_UNDO]: a paste, or typing over a selection, is a
        // step; typing goes on one until a word is begun
        if (text_->GetSelectionLength() || newText.LengthUTF8() > 1)
            Snapshot(EDIT_STEP);
        else
            Snapshot(EDIT_TYPE, IsWordChar(newText.AtUTF8(0)) &&
                (cursorPosition_ == 0 || !IsWordChar(line_.AtUTF8(cursorPosition_ - 1))));
        if (!text_->GetSelectionLength())
        {
            if (cursorPosition_ == line_.LengthUTF8())
                line_ += newText;
            else
                line_ = line_.SubstringUTF8(0, cursorPosition_) + newText + line_.SubstringUTF8(cursorPosition_);
            cursorPosition_ += newText.LengthUTF8();
        }
        else
        {
            // If a selection exists, erase it first
            unsigned start = text_->GetSelectionStart();
            unsigned length = text_->GetSelectionLength();
            if (start + length < line_.LengthUTF8())
                line_ = line_.SubstringUTF8(0, start) + newText + line_.SubstringUTF8(start + length);
            else
                line_ = line_.SubstringUTF8(0, start) + newText;
            cursorPosition_ = start + newText.LengthUTF8();
        }
        changed = true;
    }

    if (changed)
    {
        text_->ClearSelection();
        UpdateText();
        UpdateCursor();
    }
}

void LineEdit::SetText(const String& text)
{
    if (text != line_)
    {
        // buildat [TEXT_UNDO]: a script's change is a step too, but for a
        // field's first text
        if (!line_.Empty())
            Snapshot(EDIT_STEP);
        line_ = text;
        cursorPosition_ = line_.LengthUTF8();
        UpdateText();
        UpdateCursor();
    }
}

void LineEdit::SetTextAsTyped(const String& text)
{
    if (text == line_)
        return;
    // A change of more than a character (a cut, the browser's word delete)
    // is a step of its own
    int d = (int)text.LengthUTF8() - (int)line_.LengthUTF8();
    Snapshot(d > 1 || d < -1 ? EDIT_STEP : d < 0 ? EDIT_ERASE : EDIT_TYPE);
    line_ = text;
    cursorPosition_ = line_.LengthUTF8();
    UpdateText();
    UpdateCursor();
}

void LineEdit::SetCursorPosition(unsigned position)
{
    if (position > line_.LengthUTF8() || !cursorMovable_)
        position = line_.LengthUTF8();

    if (position != cursorPosition_)
    {
        cursorPosition_ = position;
        UpdateCursor();
    }
}

void LineEdit::SetCursorBlinkRate(float rate)
{
    cursorBlinkRate_ = Max(rate, 0.0f);

    if (cursorBlinkRate_ == 0.0f)
        cursorBlinkTimer_ = 0.0f;   // Cursor does not blink, i.e. always visible
}

void LineEdit::SetMaxLength(unsigned length)
{
    maxLength_ = length;
}

void LineEdit::SetEchoCharacter(unsigned c)
{
    echoCharacter_ = c;
    UpdateText();
}

void LineEdit::SetCursorMovable(bool enable)
{
    cursorMovable_ = enable;
}

void LineEdit::SetTextSelectable(bool enable)
{
    textSelectable_ = enable;
}

void LineEdit::SetTextCopyable(bool enable)
{
    textCopyable_ = enable;
}

bool LineEdit::FilterImplicitAttributes(XMLElement& dest) const
{
    if (!BorderImage::FilterImplicitAttributes(dest))
        return false;

    XMLElement childElem = dest.GetChild("element");
    if (!childElem)
        return false;
    if (!RemoveChildXML(childElem, "Name", "LE_Text"))
        return false;
    if (!RemoveChildXML(childElem, "Position"))
        return false;

    childElem = childElem.GetNext("element");
    if (!childElem)
        return false;
    if (!RemoveChildXML(childElem, "Name", "LE_Cursor"))
        return false;
    if (!RemoveChildXML(childElem, "Priority", "1"))
        return false;
    if (!RemoveChildXML(childElem, "Position"))
        return false;
    if (!RemoveChildXML(childElem, "Is Visible"))
        return false;

    return true;
}

void LineEdit::SetMultiLine(bool enable)
{
    multiLine_ = enable;
    text_->SetWordwrap(enable);
    UpdateCursor();
}

void LineEdit::UpdateText()
{
    unsigned utf8Length = line_.LengthUTF8();

    if (!echoCharacter_)
        text_->SetText(line_);
    else
    {
        String echoText;
        for (unsigned i = 0; i < utf8Length; ++i)
            echoText.AppendUTF8(echoCharacter_);
        text_->SetText(echoText);
    }
    if (cursorPosition_ > utf8Length)
    {
        cursorPosition_ = utf8Length;
        UpdateCursor();
    }

    using namespace TextChanged;

    VariantMap& eventData = GetEventDataMap();
    eventData[P_ELEMENT] = this;
    eventData[P_TEXT] = line_;
    SendEvent(E_TEXTCHANGED, eventData);
}

void LineEdit::UpdateCursor(bool follow)
{
    // buildat: the text wraps at the edit's width, so it is set before
    // the cursor's place is read
    if (multiLine_)
        text_->SetFixedWidth(Max(GetWidth() - GetIndentWidth() - clipBorder_.left_ - clipBorder_.right_ -
            cursor_->GetWidth(), 1));
    IntVector2 at = VectorRoundToInt(text_->GetCharPosition(cursorPosition_));
    int x = at.x_;
    int y = multiLine_ ? at.y_ : 0;

    text_->SetPosition(GetIndentWidth() + clipBorder_.left_, clipBorder_.top_);
    cursor_->SetPosition(text_->GetPosition() + IntVector2(x, y));
    cursor_->SetSize(cursor_->GetWidth(), text_->GetRowHeight());

    IntVector2 screenPosition = ElementToScreen(cursor_->GetPosition());
    SDL_Rect rect = {screenPosition.x_, screenPosition.y_, cursor_->GetSize().x_, cursor_->GetSize().y_};
    SDL_SetTextInputRect(&rect);

    // Scroll if necessary
    int sx = -GetChildOffset().x_;
    int left = clipBorder_.left_;
    int right = GetWidth() - clipBorder_.left_ - clipBorder_.right_ - cursor_->GetWidth();
    if (x - sx > right)
        sx = x - right;
    if (x - sx < left)
        sx = x - left;
    if (sx < 0)
        sx = 0;
    // buildat: and vertically, for a multi-line edit
    int sy = 0;
    if (multiLine_)
    {
        sy = -GetChildOffset().y_;
        int bottom = GetHeight() - clipBorder_.top_ - clipBorder_.bottom_ - text_->GetRowHeight();
        if (follow && y - sy > bottom)
            sy = y - bottom;
        if (follow && y - sy < 0)
            sy = y;
        if (!follow)
            sy = Min(sy, Max(text_->GetHeight() - (GetHeight() - clipBorder_.top_ - clipBorder_.bottom_), 0));
        if (sy < 0)
            sy = 0;
    }
    SetChildOffset(IntVector2(-sx, -sy));

    // Restart blinking
    cursorBlinkTimer_ = 0.0f;
}

// buildat: the text's vertical scroll, from nought to the text's height less
// the edit's
static int MaxScrollY(const LineEdit* edit, const Text* text, const IntRect& clip)
{
    return Max(text->GetHeight() - (edit->GetHeight() - clip.top_ - clip.bottom_), 0);
}

bool LineEdit::WheelScrolls(int delta) const
{
    if (!multiLine_ || delta == 0)
        return false;
    int sy = -GetChildOffset().y_;
    return delta > 0 ? sy > 0 : sy < MaxScrollY(this, text_, clipBorder_);
}

void LineEdit::OnWheel(int delta, int buttons, int qualifiers)
{
    // Over the edit only: the UI hands the wheel to the focus wherever the
    // mouse is, and the page under the mouse is then the one to scroll
    UI* ui = GetSubsystem<UI>();
    Input* input = GetSubsystem<Input>();
    if (!WheelScrolls(delta) || !ui || !input)
        return;
    IntVector2 mouse = input->GetMousePosition();
    IntVector2 at((int)(mouse.x_ / ui->GetScale()), (int)(mouse.y_ / ui->GetScale()));
    if (!IsInside(at, true))
        return;
    // Three rows a click, the cursor left where it is; UpdateCursor()
    // brings it back into view at the next key
    int sy = -GetChildOffset().y_ - delta * 3 * text_->GetRowHeight();
    sy = Clamp(sy, 0, MaxScrollY(this, text_, clipBorder_));
    SetChildOffset(IntVector2(GetChildOffset().x_, -sy));
}

unsigned LineEdit::GetCharIndex(const IntVector2& position)
{
    IntVector2 screenPosition = ElementToScreen(position);
    IntVector2 textPosition = text_->ScreenToElement(screenPosition);

    if (multiLine_)
        return GetCharIndexOnRow(textPosition);

    if (textPosition.x_ < 0)
        return 0;

    for (int i = text_->GetNumChars(); i >= 0; --i)
    {
        if (textPosition.x_ >= text_->GetCharPosition((unsigned)i).x_)
            return (unsigned)i;
    }

    return M_MAX_UNSIGNED;
}

unsigned LineEdit::GetCharIndexOnRow(const IntVector2& textPosition)
{
    unsigned n = text_->GetNumChars();
    int row = text_->GetRowHeight();
    // Above the first row is the first, below the last the last
    int y = Clamp(textPosition.y_, 0, (int)text_->GetCharPosition(n).y_);
    unsigned best = M_MAX_UNSIGNED;
    for (unsigned i = 0; i <= n; ++i)
    {
        IntVector2 p = VectorRoundToInt(text_->GetCharPosition(i));
        if (y >= p.y_ && y < p.y_ + row && (best == M_MAX_UNSIGNED || p.x_ <= textPosition.x_))
            best = i;
    }
    return best == M_MAX_UNSIGNED ? n : best;
}

void LineEdit::HandleFocused(StringHash /*eventType*/, VariantMap& eventData)
{
    if (eventData[Focused::P_BYKEY].GetBool())
    {
        cursorPosition_ = line_.LengthUTF8();
        text_->SetSelection(0);
    }
    UpdateCursor();

    if (GetSubsystem<UI>()->GetUseScreenKeyboard())
        GetSubsystem<Input>()->SetScreenKeyboardVisible(true);
}

void LineEdit::HandleDefocused(StringHash /*eventType*/, VariantMap& /*eventData*/)
{
    text_->ClearSelection();

    if (GetSubsystem<UI>()->GetUseScreenKeyboard())
        GetSubsystem<Input>()->SetScreenKeyboardVisible(false);
}

void LineEdit::HandleLayoutUpdated(StringHash /*eventType*/, VariantMap& /*eventData*/)
{
    UpdateCursor(false);
}

}
