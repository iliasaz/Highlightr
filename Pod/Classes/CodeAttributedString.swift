//
//  CodeAttributedString.swift
//  Pods
//
//  Created by Illanes, J.P. on 4/19/16.
//
//

import Foundation

#if os(OSX)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

/// Highlighting Delegate
@objc public protocol HighlightDelegate
{
    /**
     If this method returns *false*, the highlighting process will be skipped for this range.
     
     - parameter range: NSRange
     
     - returns: Bool
     */
    @objc optional func shouldHighlight(_ range:NSRange) -> Bool
    
    /**
     Called after a range of the string was highlighted, if there was an error **success** will be *false*.
     
     - parameter range:   NSRange
     - parameter success: Bool
     */
    @objc optional func didHighlight(_ range:NSRange, success: Bool)
}

/// NSTextStorage subclass. Can be used to dynamically highlight code.
open class CodeAttributedString : NSTextStorage
{
    /// Internal Storage
    let stringStorage = NSTextStorage()

    /// Highlightr instace used internally for highlighting. Use this for configuring the theme.
    public let highlightr: Highlightr
    
    /// This object will be notified before and after the highlighting.
    open var highlightDelegate : HighlightDelegate?

    /**
     Initialize the CodeAttributedString

     - parameter highlightr: The highlightr instance to use. Defaults to `Highlightr()`.

     */
    public init(highlightr: Highlightr = Highlightr()!)
    {
        self.highlightr = highlightr
        super.init()
        setupListeners()
    }

    /// Initialize the CodeAttributedString
    public override init() {
        self.highlightr = Highlightr()!
        super.init()
        setupListeners()
    }
    
    /// Initialize the CodeAttributedString
    required public init?(coder aDecoder: NSCoder)
    {
        self.highlightr = Highlightr()!
        super.init(coder: aDecoder)
        setupListeners()
    }
    
    #if os(OSX)
    /// Initialize the CodeAttributedString
    required public init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType)
    {
        self.highlightr = Highlightr()!
        super.init(pasteboardPropertyList: propertyList, ofType: type)
        setupListeners()
    }
    #endif
    
    /// Language syntax to use for highlighting. Providing nil will disable highlighting.
    open var language : String?
    {
        didSet
        {
            highlight(NSMakeRange(0, stringStorage.length))
        }
    }
    
    /// Returns a standard String based on the current one.
    open override var string: String
    {
        get
        {
            return stringStorage.string
        }
    }
    
    /**
     Returns the attributes for the character at a given index.
     
     - parameter location: Int
     - parameter range:    NSRangePointer
     
     - returns: Attributes
     */
    open override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [AttributedStringKey : Any]
    {
        return stringStorage.attributes(at: location, effectiveRange: range)
    }
    
    /**
     Replaces the characters at the given range with the provided string.
     
     - parameter range: NSRange
     - parameter str:   String
     */
    open override func replaceCharacters(in range: NSRange, with str: String)
    {
        stringStorage.replaceCharacters(in: range, with: str)
        self.edited(TextStorageEditActions.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
    }
    
    /**
     Sets the attributes for the characters in the specified range to the given attributes.
     
     - parameter attrs: [String : AnyObject]
     - parameter range: NSRange
     */
    open override func setAttributes(_ attrs: [AttributedStringKey : Any]?, range: NSRange)
    {
        stringStorage.setAttributes(attrs, range: range)
        self.edited(TextStorageEditActions.editedAttributes, range: range, changeInLength: 0)
    }
    
    /// Called internally everytime the string is modified.
    open override func processEditing()
    {
        super.processEditing()
        
        if language != nil {
            if self.editedMask.contains(.editedCharacters)
            {
                let string = (self.string as NSString)
                let paragraphRange = string.paragraphRange(for: editedRange)
                // remove paragraph end
                let range = NSRange(location: paragraphRange.location, length: max(0,paragraphRange.length-1))
                highlight(range)
            }
        }
    }

    func highlight(_ range: NSRange)
    {
        guard range.length > 0 else { return }
        // limit highlighting to smaller texts for now
//        guard range.length < 50000 else { return }
        // TODO: improve large text highlighting
        
        if(language == nil)
        {
            return;
        }
        
        if let highlightDelegate = highlightDelegate
        {
            let shouldHighlight : Bool? = highlightDelegate.shouldHighlight?(range)
            if(shouldHighlight != nil && !shouldHighlight!)
            {
                return;
            }
        }
        
        Task.detached(priority: .background) {
            await self.highlightAsync(range)
        }
        
//        if range.length < 120 { // typically, one line
//            highlightSync(range)
//        } else {
//            Task.detached(priority: .background) {
//                await self.highlightAsync(range)
//            }
//        }
    }
    
    func highlightAsync(_ range: NSRange) async {
        let string = (self.string as NSString)
        
        // minor changes in the text
        if range.length < string.length {
            let line = string.substring(with: range)
            guard let tmpStrg = self.highlightr.highlight(line, as: self.language!) else { return }
            
            if !shouldProcessHighlights(highlightedString: tmpStrg, range: range)  { return }
            
            await MainActor.run {
                applyHighlighting(highlightedString: tmpStrg, in: range)
            }
        } else {
            guard let tmpStrg = self.highlightr.highlight(self.string, as: self.language!) else { return }
            if !shouldProcessHighlights(highlightedString: tmpStrg, range: range)  { return }
            let copy = applyHighlightingToEntireText(highlightedString: tmpStrg, in: range)
            await MainActor.run {
                beginEditing()
                self.stringStorage.setAttributedString(copy)
                endEditing()
                self.edited(TextStorageEditActions.editedAttributes, range: range, changeInLength: 0)
                self.highlightDelegate?.didHighlight?(range, success: true)
            }
        }
    }
    
    func shouldProcessHighlights(highlightedString: NSAttributedString, range: NSRange) -> Bool {
        if((range.location + range.length) > self.stringStorage.length) {
            self.highlightDelegate?.didHighlight?(range, success: false)
            return false;
        }

        if(highlightedString.string != self.stringStorage.attributedSubstring(from: range).string) {
            self.highlightDelegate?.didHighlight?(range, success: false)
            return false;
        }
        return true
    }
    
    func applyHighlighting(highlightedString tmpStrg: NSAttributedString, in range: NSRange) {
        self.beginEditing()
        tmpStrg.enumerateAttributes(in: NSMakeRange(0, tmpStrg.length), options: [.longestEffectiveRangeNotRequired], using: { (attrs, locRange, stop) in
            var fixedRange = NSMakeRange(range.location+locRange.location, locRange.length)
            fixedRange.length = (fixedRange.location + fixedRange.length < self.string.count) ? fixedRange.length : self.string.count-fixedRange.location
            fixedRange.length = (fixedRange.length >= 0) ? fixedRange.length : 0
            self.stringStorage.addAttributes(attrs, range: fixedRange)
        })
        self.endEditing()
        self.edited(TextStorageEditActions.editedAttributes, range: range, changeInLength: 0)
        self.highlightDelegate?.didHighlight?(range, success: true)
    }
    
    func applyHighlightingToEntireText(highlightedString tmpStrg: NSAttributedString, in range: NSRange) -> NSMutableAttributedString {
        let copy = self.stringStorage.mutableCopy() as! NSMutableAttributedString
        tmpStrg.enumerateAttributes(in: NSMakeRange(0, tmpStrg.length), options: [.longestEffectiveRangeNotRequired], using: { (attrs, locRange, stop) in
            var fixedRange = NSMakeRange(range.location+locRange.location, locRange.length)
            fixedRange.length = (fixedRange.location + fixedRange.length < self.string.count) ? fixedRange.length : self.string.count-fixedRange.location
            fixedRange.length = (fixedRange.length >= 0) ? fixedRange.length : 0
            copy.addAttributes(attrs, range: fixedRange)
        })
        return copy
    }
    
    func setupListeners()
    {
        highlightr.themeChanged =
            { [weak self] _ in
                guard let self = self else { return }
                let range = NSMakeRange(0, self.stringStorage.length)
                self.highlight(range)
        }
    }
}

extension NSAttributedString: @unchecked Sendable {}
