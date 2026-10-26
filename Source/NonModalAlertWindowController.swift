// Copyright (c) 2022 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Cocoa

@objc protocol NonModalAlertWindowControllerDelegate: AnyObject {
    func nonModalAlertWindowControllerDidConfirm(_ controller: NonModalAlertWindowController)
    func nonModalAlertWindowControllerDidCancel(_ controller: NonModalAlertWindowController)
}

class NonModalAlertWindowController: NSWindowController {
    @objc(sharedInstance)
    static let shared = NonModalAlertWindowController(
        windowNibName: "NonModalAlertWindowController")

    @IBOutlet weak var titleTextField: NSTextField!
    @IBOutlet weak var contentTextField: NSTextField!
    @IBOutlet weak var confirmButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    weak var delegate: NonModalAlertWindowControllerDelegate?

    var dismissOnConfirm: Bool = true

    private var contentScrollView: NSScrollView?
    private var contentTextView: NSTextView?
    private let baseWindowWidth: CGFloat = 420.0
    private let baseWindowHeight: CGFloat = 130.0
    private let expandedWindowWidth: CGFloat = 500.0

    func setWorkingStatus(title: String, message: String) {
        titleTextField.stringValue = title
        contentTextField.stringValue = message
        contentTextField.isHidden = false
        contentScrollView?.isHidden = true
        confirmButton.isEnabled = false
        confirmButton.title = "處理中..."
        cancelButton.isEnabled = false
    }

    @objc func show(
        title: String, content: String, confirmButtonTitle: String, cancelButtonTitle: String?,
        cancelAsDefault: Bool, delegate: NonModalAlertWindowControllerDelegate?
    ) {
        _ = self.window

        if window?.isVisible == true {
            self.delegate?.nonModalAlertWindowControllerDidCancel(self)
        }

        self.delegate = delegate
        confirmButton.isEnabled = true
        confirmButton.title = confirmButtonTitle
        if let cancelButtonTitle = cancelButtonTitle {
            cancelButton.title = cancelButtonTitle
            cancelButton.isHidden = false
            cancelButton.isEnabled = true
        } else {
            cancelButton.isHidden = true
        }

        cancelButton.nextKeyView = confirmButton
        confirmButton.nextKeyView = cancelButton
        if cancelButtonTitle != nil {
            if cancelAsDefault {
                window?.defaultButtonCell = cancelButton.cell as? NSButtonCell
            } else {
                cancelButton.keyEquivalent = "\u{1b}"
                window?.defaultButtonCell = confirmButton.cell as? NSButtonCell
            }
        } else {
            window?.defaultButtonCell = confirmButton.cell as? NSButtonCell
        }

        titleTextField.stringValue = title

        // Determine screen bounds to guarantee the window & buttons NEVER exceed the display
        let targetScreen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleRect = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWindowHeight = min(visibleRect.height - 100.0, 520.0)

        let testFont = contentTextField?.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let availableTextWidth = expandedWindowWidth - 102.0 - 20.0
        let infiniteHeightFrame = NSRect(origin: .zero, size: CGSize(width: availableTextWidth, height: 10240))
        let estimatedContentRect = (content as NSString).boundingRect(
            with: infiniteHeightFrame.size,
            options: [.usesLineFragmentOrigin],
            attributes: [.font: testFont]
        )
        let contentHeight = ceil(estimatedContentRect.height)
        let isLongContent = contentHeight > 140.0

        let windowWidth: CGFloat = isLongContent ? expandedWindowWidth : baseWindowWidth
        let desiredHeight: CGFloat = isLongContent
            ? min(max(340.0, baseWindowHeight + contentHeight), maxWindowHeight)
            : min(baseWindowHeight + max(0, contentHeight - 14.0), maxWindowHeight)
        let windowHeight: CGFloat = desiredHeight

        // Strictly clamp origin inside visible screen bounds so buttons are ALWAYS accessible
        var originX = visibleRect.midX - windowWidth / 2.0
        var originY = visibleRect.midY - windowHeight / 2.0
        originX = max(visibleRect.minX + 20.0, min(originX, visibleRect.maxX - windowWidth - 20.0))
        originY = max(visibleRect.minY + 30.0, min(originY, visibleRect.maxY - windowHeight - 30.0))

        let windowFrame = NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight)
        window?.setFrame(windowFrame, display: true)
        window?.isMovableByWindowBackground = true

        if isLongContent, let contentView = window?.contentView {
            contentTextField.isHidden = true

            let scrollX: CGFloat = 102.0
            let scrollBottom: CGFloat = 56.0
            let scrollWidth: CGFloat = windowWidth - scrollX - 20.0
            let scrollTop: CGFloat = titleTextField.frame.minY - 8.0
            let scrollHeight: CGFloat = max(80.0, scrollTop - scrollBottom)
            let scrollFrame = NSRect(x: scrollX, y: scrollBottom, width: scrollWidth, height: scrollHeight)

            if contentScrollView == nil {
                let scrollView = NSScrollView(frame: scrollFrame)
                scrollView.hasVerticalScroller = true
                scrollView.hasHorizontalScroller = false
                scrollView.autohidesScrollers = true
                scrollView.borderType = .bezelBorder

                let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
                textView.minSize = NSSize(width: 0.0, height: scrollView.contentSize.height)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.isVerticallyResizable = true
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                textView.textContainer?.widthTracksTextView = true
                textView.isEditable = false
                textView.isSelectable = true
                textView.textContainerInset = NSSize(width: 6, height: 6)
                textView.font = testFont

                scrollView.documentView = textView
                contentView.addSubview(scrollView)

                self.contentScrollView = scrollView
                self.contentTextView = textView
            } else {
                contentScrollView?.frame = scrollFrame
                contentScrollView?.isHidden = false
            }

            contentTextView?.string = content
            contentTextView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
        } else {
            contentScrollView?.isHidden = true
            contentTextField.isHidden = false
            contentTextField.stringValue = content
        }

        window?.level = NSWindow.Level(Int(CGShieldingWindowLevel()) + 1)
        window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func confirmButtonAction(_ sender: Any) {
        delegate?.nonModalAlertWindowControllerDidConfirm(self)
        if dismissOnConfirm {
            window?.orderOut(self)
        }
    }

    @IBAction func cancelButtonAction(_ sender: Any) {
        cancel(sender)
    }

    func cancel(_ sender: Any) {
        delegate?.nonModalAlertWindowControllerDidCancel(self)
        delegate = nil
        window?.orderOut(self)
    }

}
