import Foundation

struct HistoryLine
{
  let childIndex, parentIndex: UInt?
  let colorIndex: UInt
}

public class CommitEntry: CustomStringConvertible
{
  let commit: Commit
  fileprivate(set) var lines = [HistoryLine]()
  var dotOffset: UInt?
  var dotColorIndex: UInt?
  
  public var description: String
  { return commit.description }
  
  init(commit: Commit)
  {
    self.commit = commit
  }
}

public func == (left: CommitEntry, right: CommitEntry) -> Bool
{
  // TODO: Make OID equatable to compare commit.oid
  return left.commit.sha == right.commit.sha
}


/// A connection line between commits in the history list.
struct CommitConnection<ID: OID>: Equatable
{
  let parentOID, childOID: ID
  let colorIndex: UInt
}

func == <ID>(left: CommitConnection<ID>, right: CommitConnection<ID>) -> Bool
{
  return left.parentOID.equals(right.parentOID) &&
         left.childOID.equals(right.childOID) &&
         (left.colorIndex == right.colorIndex)
}

// Specific version: compare the binary OIDs
func == (left: CommitConnection<GitOID>, right: CommitConnection<GitOID>) -> Bool
{
  return left.parentOID.equals(right.parentOID) &&
         left.childOID.equals(right.childOID) &&
         (left.colorIndex == right.colorIndex)
}


extension String
{
  func firstSix() -> String
  {
    return prefix(6).description
  }
}


/// The result of processing a segment of a branch.
struct BranchResult
{
  /// The commit entries collected for this segment.
  let entries: [CommitEntry]
  /// Other branches queued for processing.
  let queue: [(commit: Commit, after: Commit)]
}

extension BranchResult: CustomStringConvertible
{
  var description: String
  {
    guard let first = entries.first?.commit.sha.firstSix(),
          let last = entries.last?.commit.sha.firstSix()
    else { return "empty" }
    
    return "\(first)..\(last)"
  }
}

public typealias GitCommitHistory = CommitHistory<GitOID>

/// Maintains the history list, allowing for dynamic adding and removing.
public class CommitHistory<ID: OID & Hashable>: NSObject
{
  public typealias Entry = CommitEntry
  typealias Connection = CommitConnection<ID>
  typealias Result = BranchResult

  weak var repository: CommitStorage!
  
  var commitLookup = [ID: Entry]()
  var entries = [Entry]()
  private var abortFlag = false
  private var abortMutex = Mutex()
  
  // batchSize, batch, pass, value
  // HistoryTableController.postProgress assumes 2 passes.
  var postProgress: ((Int, Int, Int, Int) -> Void)?
  
  /// Manually appends a commit.
  func appendCommit(_ commit: Commit)
  {
    entries.append(Entry(commit: commit))
  }
  
  /// Clears the history list.
  public func reset()
  {
    abort()
    commitLookup.removeAll()
    objc_sync_enter(self)
    entries.removeAll()
    objc_sync_exit(self)
    resetAbort()
  }
  
  /// Signals that processing should be stopped.
  public func abort()
  {
    abortMutex.withLock {
      abortFlag = true
    }
  }
  
  public func resetAbort()
  {
    abortMutex.withLock {
      abortFlag = false
    }
  }
  
  func checkAbort() -> Bool
  {
    return abortMutex.withLock { abortFlag }
  }
  
  /// Creates a list of commits for the branch starting at the given commit, and
  /// also a list of secondary parents that may start other branches. A branch
  /// segment ends when a commit has more than one parent, or its parent is
  /// already registered.
  private func branchEntries(startCommit: Commit) -> Result
  {
    var commit = startCommit
    var result = [Entry(commit: startCommit)]
    var queue = [(commit: Commit, after: Commit)]()
    
    while let firstParentOID = commit.parentOIDs.first as? ID {
      for parentOID in commit.parentOIDs.dropFirst() {
        if let parentCommit = repository.commit(forOID: parentOID as! ID) {
          queue.append((parentCommit, commit))
        }
      }
      
      guard commitLookup[firstParentOID] == nil,
            let parentCommit = repository.commit(forOID: firstParentOID)
      else { break }

      if commit.parentOIDs.count > 1 {
        queue.append((parentCommit, commit))
        break
      }
      
      result.append(CommitEntry(commit: parentCommit))
      commit = parentCommit
    }
    
    let branchResult = Result(entries: result, queue: queue)
    
#if DEBUGLOG
    let before = entries.last?.commit.parentOIDs.map { $0.SHA.firstSix() }
                        .joinWithSeparator(" ")
    
    print("\(branchResult) ‹ \(before ?? "-")", terminator: "")
    for (commit, after) in queue {
      print(" (\(commit.SHA!.firstSix()) › \(after.SHA!.firstSix()))",
            terminator: "")
    }
    print("")
#endif
    return branchResult
  }
  
  /// Adds new commits to the list.
  public func process(_ startCommit: Commit, afterCommit: Commit? = nil)
  {
    let startOID = startCommit.oid as! ID
    guard commitLookup[startOID] == nil
    else { return }
    
    var results = [Result]()
    var startCommit = startCommit
    
    repeat {
      var result = branchEntries(startCommit: startCommit)
      
      defer { results.append(result) }
      if let nextOID = result.entries.last?.commit.parentOIDs.first as? ID,
         commitLookup[nextOID] == nil,
         let nextCommit = repository.commit(forOID: nextOID) {
        startCommit = nextCommit
      }
      else {
        break
      }
    } while true
    
    for result in results.reversed() {
      if checkAbort() {
        break
      }
      for (parent, after) in result.queue.reversed() {
        process(parent, afterCommit: after)
      }
      processBranchResult(result, after: afterCommit)
    }
  }
  
  private func processBranchResult(_ result: Result, after afterCommit: Commit?)
  {
    for branchEntry in result.entries {
      commitLookup[branchEntry.commit.oid as! ID] = branchEntry
    }
    
    let afterIndex = afterCommit.flatMap
        { commit in entries.index { $0.commit.oid.equals(commit.oid) } }
    guard let lastEntry = result.entries.last
    else { return }
    let lastParentOIDs = lastEntry.commit.parentOIDs
    
    if let insertBeforeIndex = lastParentOIDs.compactMap(
           { oid in entries.index(where: { $0.commit.oid.equals(oid) }) })
           .sorted().first {
      #if DEBUGLOG
      print(" ** \(insertBeforeIndex) before \(entries[insertBeforeIndex].commit)")
      #endif
      if let afterIndex = afterIndex ,
         afterIndex < insertBeforeIndex {
        #if DEBUGLOG
        print(" *** \(result) after \(afterCommit?.description ?? "")")
        #endif
        entries.insert(contentsOf: result.entries, at: afterIndex + 1)
      }
      else {
        #if DEBUGLOG
        print(" *** \(result) before \(entries[insertBeforeIndex].commit) " +
              "(after \(afterCommit?.description ?? "-"))")
        #endif
        entries.insert(contentsOf: result.entries, at: insertBeforeIndex)
      }
    }
    else if let lastSecondaryOID = result.queue.last?.after.oid as? ID,
            let lastSecondaryEntry = commitLookup[lastSecondaryOID],
            let lastSecondaryIndex = entries.index(where:
                { $0.commit.oid.equals(lastSecondaryEntry.commit.oid) }) {
      #if DEBUGLOG
      print(" ** after secondary \(lastSecondaryOID.SHA!.firstSix())")
      #endif
      entries.insert(contentsOf: result.entries, at: lastSecondaryIndex)
    }
    else if let afterIndex = afterIndex {
      #if DEBUGLOG
      print(" ** \(result) after \(afterCommit?.description ?? "")")
      #endif
      entries.insert(contentsOf: result.entries, at: afterIndex + 1)
    }
    else {
      #if DEBUGLOG
      print(" ** appending \(result)")
      #endif
      entries.append(contentsOf: result.entries)
    }
  }
  
  /// Creates the connections to be drawn between commits.
  public func connectCommits(batchSize: Int = 0,
                             batchNotify: (() -> Void)? = nil)
  {
    let batchSize = batchSize <= 0 ? entries.count : batchSize
    var batchStart = 0
    var startingConnections = [Connection]()
    
    while batchStart < entries.count {
      if checkAbort() {
        break
      }

      let batchSize = min(batchSize, entries.count - batchStart)
      let (connections, newStart) =
            generateConnections(batchStart: batchStart,
                                batchSize: batchSize,
                                starting: startingConnections)
      
      signpostStart(.generateLines, UInt(batchStart))
      DispatchQueue.concurrentPerform(iterations: batchSize) {
        (index) in
        guard !checkAbort() && (index + batchStart < entries.count)
        else { return }
        
        objc_sync_enter(self)
        let entry = entries[index + batchStart]
        objc_sync_exit(self)
        
        generateLines(entry: entry, connections: connections[index])
        postProgress?(batchSize, batchStart/batchSize, 1, index)
      }
      signpostEnd(.generateLines, UInt(batchStart))

      startingConnections = newStart
      batchStart += batchSize
      batchNotify?()
    }
  }
  
  func generateConnections(batchStart: Int, batchSize: Int,
                           starting: [Connection])
    -> ([[Connection]], [Connection])
  {
    signpostStart(.generateConnections, UInt(batchStart))
    defer {
      signpostEnd(.generateConnections, UInt(batchStart))
    }
    
    var result = [[Connection]]()
    var connections: [Connection] = starting
    var nextColorIndex: UInt = 0
    
    result.reserveCapacity(batchSize)
    for (index, entry) in entries[batchStart..<batchStart+batchSize].enumerated() {
      let commitOID = entry.commit.oid as! ID
      let incomingIndex = connections.index { $0.parentOID.equals(commitOID) }
      let incomingColor = incomingIndex.flatMap { connections[$0].colorIndex }
      
      if let firstParentOID = entry.commit.parentOIDs.first {
        let newConnection = Connection(parentOID: firstParentOID as! ID,
                                       childOID: commitOID,
                                       colorIndex: incomingColor ??
                                                   nextColorIndex++)
        let insertIndex = incomingIndex.flatMap { $0 + 1 } ??
                          connections.endIndex
        
        connections.insert(newConnection, at: insertIndex)
      }
      
      // Add new connections for the commit's parents
      for parentOID in entry.commit.parentOIDs.dropFirst() {
        connections.append(Connection(parentOID: parentOID as! ID,
                                      childOID: commitOID,
                                      colorIndex: nextColorIndex++))
      }
      
      result.append(connections)
      connections = connections.filter { $0.parentOID != commitOID }
      
      postProgress?(batchSize, batchStart/batchSize, 0, index)
    }
    
    return (result, connections)
  }
  
  func generateLines(entry: CommitEntry,
                     connections: [CommitConnection<ID>])
  {
    var nextChildIndex: UInt = 0
    let parentOutlets = NSOrderedSet(array: connections.compactMap {
            ($0.parentOID.equals(entry.commit.oid)) ? nil : $0.parentOID })
    var parentLines: [ID: (childIndex: UInt,
                           colorIndex: UInt)] = [:]
    var generatedLines: [HistoryLine] = []
    
    for connection in connections {
      let commitIsParent = connection.parentOID.equals(entry.commit.oid)
      let commitIsChild = connection.childOID.equals(entry.commit.oid)
      let parentIndex: UInt? = commitIsParent
              ? nil : UInt(parentOutlets.index(of: connection.parentOID))
      var childIndex: UInt? = commitIsChild
              ? nil : nextChildIndex
      var colorIndex = connection.colorIndex
      
      if (entry.dotOffset == nil) && (commitIsParent || commitIsChild) {
        entry.dotOffset = nextChildIndex
        entry.dotColorIndex = colorIndex
      }
      if let parentLine = parentLines[connection.parentOID] {
        if !commitIsChild {
          childIndex = parentLine.childIndex
          colorIndex = parentLine.colorIndex
        }
        else if !commitIsParent {
          nextChildIndex += 1
        }
      }
      else {
        if !commitIsChild {
          parentLines[connection.parentOID] = (
              childIndex: nextChildIndex,
              colorIndex: colorIndex)
        }
        if !commitIsParent {
          nextChildIndex += 1
        }
      }
      generatedLines.append(HistoryLine(childIndex: childIndex,
                                        parentIndex: parentIndex,
                                        colorIndex: colorIndex))
    }
    objc_sync_enter(self)
    entry.lines.append(contentsOf: generatedLines)
    objc_sync_exit(self)
  }
}
