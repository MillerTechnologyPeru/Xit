import Foundation

class BlameViewController: XTWebViewController, TabWidthVariable
{
  @IBOutlet var spinner: NSProgressIndicator!
  
  let actionDelegate: BlameActionDelegate
  
  weak var repoController: RepositoryController!
  {
    return view.window?.windowController as? RepositoryController
  }
  
  override init?(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?)
  {
    actionDelegate = BlameActionDelegate()
    
    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    
    actionDelegate.controller = self
  }
  
  required init?(coder: NSCoder)
  {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func webActionDelegate() -> Any
  {
    return actionDelegate
  }
  
  func notAvailable()
  {
    DispatchQueue.main.async {
      [weak self] in
      self?.loadNotice("Blame not available")
    }
  }
  
  func nextColor(lastHue: inout Int) -> NSColor
  {
    let hue = CGFloat(lastHue%360)/360.0
  
    lastHue += 55
    return NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.85,
                   alpha: 1.0)
  }
  
  func loadBlame(text: String, path: String,
                 model: XTFileChangesModel, staged: Bool)
  {
    defer {
      DispatchQueue.main.async {
        [weak self] in
        self?.spinner.isHidden = true
        self?.spinner.stopAnimation(nil)
      }
    }
    
    guard let blame = (model as? Blaming)?.blame(for: path, staged: staged)
    else {
      notAvailable()
      return
    }
    
    var htmlLines = [String]()
    let lines = text.components(separatedBy: .newlines)
    var commitColors = [GitOID: NSColor]()
    var lastHue = 120
    
    for hunk in blame.hunks {
      var color: NSColor! = commitColors[hunk.finalOID]
      
      if color == nil {
        color = nextColor(lastHue: &lastHue)
        commitColors[hunk.finalOID] = color
      }
      
      htmlLines.append(contentsOf: [
          "<tr><td class='blamehead' style='background-color: \(color.cssHSL)'>",
          "<div class='name'>\(hunk.finalSignature.name ?? "")</div>"
          ])
      
      if hunk.lineCount > 1 {
        if hunk.finalOID.isZero {
          htmlLines.append("<div class='local'>local changes</div>")
        }
        else {
          htmlLines.append(
              "<div class='sha' " +
              "onclick=\"window.webActionDelegate.selectSHA('" +
              hunk.finalOID.sha + "')\">" +
              hunk.finalOID.sha.firstSix() + "</div>")
        }
      }
      color = color.blended(withFraction: 0.65, of: .white)
      htmlLines.append(contentsOf: ["</td>",
                                    "<td style='background-color: \(color.cssHSL)'>"])
      
      let start = hunk.finalLineStart - 1
      let end = min(start + hunk.lineCount, lines.count-1)
      let hunkLines = lines[start..<end]
      
      htmlLines.append(contentsOf: hunkLines.map {
        "<div class='line'>" +
        "\(XTWebViewController.escapeText($0))</div>" })
      htmlLines.append("</td></tr>")
    }
    
    let htmlTemplate = XTWebViewController.htmlTemplate("blame")
    let html = String(format: htmlTemplate, htmlLines.joined(separator: "\n"))
    
    DispatchQueue.main.async {
      [weak self] in
      self?.webView?.mainFrame.loadHTMLString(
        html, baseURL: XTWebViewController.baseURL())
    }
  }
}

extension BlameViewController: XTFileContentController
{
  func clear()
  {
    webView?.mainFrame.loadHTMLString("", baseURL: nil)
  }
  
  public func load(path: String!, model: XTFileChangesModel!, staged: Bool)
  {
    guard let data = model.dataForFile(path, staged: staged),
          let text = String(data: data, encoding: .utf8) ??
                     String(data: data, encoding: .utf16)
    else {
      notAvailable()
      return
    }
    
    spinner.isHidden = false
    spinner.startAnimation(nil)
    clear()
    DispatchQueue.global(qos: .userInitiated).async {
      [weak self] in
      self?.loadBlame(text: text, path: path, model: model, staged: staged)
    }
  }
}

// Similar to CommitHeaderActionDelegate, may need a refactor
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
      case #selector(CommitHeaderActionDelegate.select(sha:)):
        return "selectSHA"
      default:
        return ""
    }
  }

  @objc(selectSHA:)
  func select(sha: String)
  {
    controller?.repoController.select(sha: sha)
  }
}
