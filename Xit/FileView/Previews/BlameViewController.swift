import Foundation
import Cocoa

class BlameViewController: WebViewController
{
  @IBOutlet var spinner: NSProgressIndicator!
  var isLoaded: Bool = false
  
  // swiftlint:disable:next weak_delegate
  let actionDelegate: BlameActionDelegate
  
  var currentSelection: FileSelection?
  
  var repoController: RepositoryController?
  {
    let window: NSWindow?
    
    if Thread.isMainThread {
      window = view.window
    }
    else {
      window = DispatchQueue.main.sync {
        return view.window
      }
    }
    return window?.windowController as? RepositoryController
  }
  
  class CommitColoring
  {
    var commitColors = [String: NSColor]()
    var lastHue = 120
    
    init(firstOID: OID)
    {
      _ = color(for: firstOID)
    }
    
    func color(for oid: OID) -> NSColor
    {
      if let color = commitColors[oid.sha] {
        return color
      }
      else {
        let blameStart = NSColor(named: "blameStart")!
        let result = blameStart.withHue(CGFloat(lastHue) / 360.0)
        
        lastHue = (lastHue + 55) % 360
        commitColors[oid.sha] = result
        return result
      }
    }
  }
  
  override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?)
  {
    actionDelegate = BlameActionDelegate()
    
    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    
    actionDelegate.controller = self
  }
  
  required init?(coder: NSCoder)
  {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func loadNotice(_ text: UIString)
  {
    spinner.isHidden = true
    spinner.stopAnimation(nil)
    super.loadNotice(text)
  }
  
  func notAvailable()
  {
    DispatchQueue.main.async {
      [weak self] in
      self?.loadNotice(.blameNotAvailable)
    }
  }
  
  func loadBlame(text: String, path: String,
                 selection: RepositorySelection, fileList: FileListModel)
  {
    defer {
      DispatchQueue.main.async {
        [weak self] in
        self?.spinner.isHidden = true
        self?.spinner.stopAnimation(nil)
      }
    }
    
    guard let blame = fileList.blame(for: path)
    else {
      notAvailable()
      return
    }
    
    var htmlLines = [String]()
    let lines = text.lineComponents()
    let selectOID: GitOID? = selection.shaToSelect.map { GitOID(sha: $0) }
                             ?? nil
    let currentOID = selectOID ?? GitOID.zero()
    let dateFormatter = DateFormatter()
    let coloring = CommitColoring(firstOID: currentOID)
    
    dateFormatter.timeStyle = .short
    dateFormatter.dateStyle = .short
    
    for hunk in blame.hunks {
      let finalOID = hunk.finalLine.oid as! GitOID
      var color = coloring.color(for: finalOID)
      let jumpButton = finalOID == currentOID ? "" : """
            <div class='jumpbutton' \
            onclick="window.webActionDelegate.selectSHA('\(finalOID.sha)')">
            ‣</div>
            """

      htmlLines.append(contentsOf: ["""
          <tr><td class='headcell'>
            <div class='blamehead' style='background-color: \(color.cssHSL)'>
            \(jumpButton)
            <div class='name'>\(hunk.finalLine.signature.name ?? "")</div>
          """
          ])
      
      if hunk.lineCount > 0 {
        if hunk.finalLine.oid.isZero {
          htmlLines.append("<div class='local'>local changes</div>")
        }
        else {
          if finalOID == currentOID {
            htmlLines.append("<div class='currentsha'>" +
                             hunk.finalLine.oid.sha.firstSix() + "</div>")
          }
          else {
            htmlLines.append(
                "<div>\(hunk.finalLine.oid.sha.firstSix())</div>")
          }
        }
        htmlLines.append("""
            <div class='date'>\
            \(dateFormatter.string(from: hunk.finalLine.signature.when))</div>
            """)
      }
      if finalOID != currentOID,
         let blend = color.blended(withFraction: 0.65,
                                  of: .textBackgroundColor) {
        color = blend
      }
      htmlLines.append(contentsOf: ["</div></td>",
                                    "<td style='background-color: " +
                                    "\(color.cssHSL)'>"])
      
      let start = hunk.finalLine.start - 1
      let end = min(start + hunk.lineCount, lines.count)
      let hunkLines = lines[start..<end]
      
      htmlLines.append(contentsOf: hunkLines.map {
          "<div class='line'>\($0.xmlEscaped)</div>" })
      htmlLines.append("</td></tr>")
    }
    
    let htmlTemplate = WebViewController.htmlTemplate("blame")
    let html = String(format: htmlTemplate, htmlLines.joined(separator: "\n"))
    
    DispatchQueue.main.async {
      [weak self] in
      self?.load(html: html)
      self?.isLoaded = true
    }
  }
}

extension BlameViewController: WebActionDelegateHost
{
  var webActionDelegate: Any
  {
    return actionDelegate
  }
}

extension BlameViewController: XTFileContentController
{
  func clear()
  {
    load(html: "")
    isLoaded = false
  }
  
  public func load(selection: [FileSelection])
  {
    switch selection.count {
      case 0:
        self.clear()
        return
      case 1:
        break
      default:
        loadNotice(.multipleItemsSelected)
        return
    }
    
    guard selection[0] != currentSelection
    else { return }
    
    currentSelection = selection[0]
    repoController?.queue.executeOffMainThread {
      [weak self] in
      guard let self = self
      else { return }
      let fileList = selection[0].fileList
      guard let data = fileList.dataForFile(selection[0].path),
            let text = String(data: data, encoding: .utf8) ??
                       String(data: data, encoding: .utf16)
      else {
        self.notAvailable()
        return
      }
      
      Thread.performOnMainThread {
        self.spinner.isHidden = false
        self.spinner.startAnimation(nil)
        self.clear()
      }
      self.loadBlame(text: text, path: selection[0].path,
                     selection: selection[0].repoSelection, fileList: fileList)
    }
  }
}

class BlameActionDelegate: NSObject
{
  weak var controller: BlameViewController?
  
  override class func isSelectorExcluded(fromWebScript selector: Selector) -> Bool
  {
    switch selector {
      case #selector(BlameActionDelegate.select(sha:)):
        return false
      default:
        return true
    }
  }
  
  override class func webScriptName(for selector: Selector) -> String
  {
    switch selector {
      case #selector(BlameActionDelegate.select(sha:)):
        return "selectSHA"
      default:
        return ""
    }
  }

  @objc(selectSHA:)
  func select(sha: String)
  {
    controller?.repoController?.select(sha: sha)
  }
}
