import Foundation

// MARK: Refs
extension XTRepository: CommitReferencing
{
  var headReference: Reference?
  {
    return GitReference(headForRepo: gitRepo)
  }
  
  /// Reloads the cached map of OIDs to refs.
  func rebuildRefsIndex()
  {
    var payload = CallbackPayload(repo: self)
    let callback: git_reference_foreach_cb = {
      (reference, payload) -> Int32 in
      defer {
        git_reference_free(reference)
      }
      
      let repo = payload!.bindMemory(to: XTRepository.self,
                                     capacity: 1).pointee
      
      guard let rawName = git_reference_name(reference),
            let name = String(validatingUTF8: rawName)
      else { return 0 }
      
      var peeled: OpaquePointer?
      guard git_reference_peel(&peeled, reference, GIT_OBJECT_COMMIT) == 0
      else { return 0 }
      
      let peeledOID = git_object_id(peeled)
      guard let sha = peeledOID.map({ GitOID(oid: $0.pointee) })?.sha
      else { return 0 }
      var refs = repo.refsIndex[sha] ?? [String]()
      
      refs.append(name)
      repo.refsIndex[sha] = refs
      
      return 0
    }
    
    objc_sync_enter(self)
    defer {
      objc_sync_exit(self)
    }
    refsIndex.removeAll()
    git_reference_foreach(gitRepo, callback, &payload)
  }
  
  /// Returns a list of refs that point to the given commit.
  public func refs(at sha: String) -> [String]
  {
    objc_sync_enter(self)
    defer {
      objc_sync_exit(self)
    }
    return refsIndex[sha] ?? []
  }
  
  /// Returns a list of all ref names.
  func allRefs() -> [String]
  {
    var stringArray = git_strarray()
    guard git_reference_list(&stringArray, gitRepo) == 0
    else { return [] }
    defer { git_strarray_free(&stringArray) }
    
    return stringArray.compactMap { $0 }
  }

  public var headRef: String?
  {
    objc_sync_enter(self)
    defer {
      objc_sync_exit(self)
    }
    if cachedHeadRef == nil {
      recalculateHead()
    }
    return cachedHeadRef
  }
  
  var headSHA: String?
  {
    return headRef.map { sha(forRef: $0) } ?? nil
  }

  func calculateCurrentBranch() -> String?
  {
    return headReference?.resolve()?.name.removingPrefix(BranchPrefixes.heads)
  }

  func hasHeadReference() -> Bool
  {
    return headReference != nil
  }
  
  func parentTree() -> String
  {
    return hasHeadReference() ? "HEAD" : kEmptyTreeHash
  }
  
  public func sha(forRef ref: String) -> String?
  {
    return oid(forRef: ref)?.sha
  }
  
  func oid(forRef ref: String) -> OID?
  {
    let object = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
    let result = git_revparse_single(object, gitRepo, ref)
    guard result == 0,
          let finalObject = object.pointee,
          let oid = git_object_id(finalObject)
    else { return nil }
    
    return GitOID(oidPtr: oid)
  }
  
  func createBranch(_ name: String) -> Bool
  {
    clearCachedBranch()
    return (try? executeGit(args: ["checkout", "-b", name],
                            writes: true)) != nil
  }
  
  func deleteBranch(_ name: String) -> Bool
  {
    return writing {
      guard let branch = localBranch(named: name) as? GitLocalBranch
      else { return false }
      
      return git_branch_delete(branch.branchRef) == 0
    }
  }
  
  /// Renames the given local branch.
  @objc(renameBranch:to:error:)
  func rename(branch: String, to newName: String) throws
  {
    if isWriting {
      throw Error.alreadyWriting
    }
    
    let branchRef = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
    var result = git_branch_lookup(branchRef, gitRepo, branch, GIT_BRANCH_LOCAL)
    
    if result != 0 {
      throw NSError.git_error(for: result)
    }
    
    let newRef = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
    
    result = git_branch_move(newRef, branchRef.pointee, newName, 0)
    if result != 0 {
      throw NSError.git_error(for: result)
    }
  }
  
  public func stashes() -> Stashes
  {
    return Stashes(repo: self)
  }
  
  /// Returns the list of tags, or throws if libgit2 hit an error.
  public func tags() throws -> [Tag]
  {
    let tagNames = UnsafeMutablePointer<git_strarray>.allocate(capacity: 1)
    let result = git_tag_list(tagNames, gitRepo)
    
    try Error.throwIfError(result)
    defer { git_strarray_free(tagNames) }
    
    return tagNames.pointee.compactMap {
      name in name.flatMap { GitTag(repository: self, name: $0) }
    }
  }
  
  public func reference(named name: String) -> Reference?
  {
    return GitReference(name: name, repository: gitRepo)
  }
}

extension XTRepository: Branching
{
  @objc public var currentBranch: String?
  {
    mutex.lock()
    defer { mutex.unlock() }
    if cachedBranch == nil {
      refsChanged()
    }
    return cachedBranch
  }
  
  public func createBranch(named name: String,
                           target: String) throws -> LocalBranch?
  {
    guard let targetRef = GitReference(name: target,
                                       repository: gitRepo),
          let targetOID = targetRef.targetOID,
          let targetCommit = GitCommit(oid: targetOID, repository: gitRepo)
    else { return nil }
    
    var branchRef: OpaquePointer?
    let result = git_branch_create(&branchRef, gitRepo, name,
                                   targetCommit.commit, 0)
    
    try Error.throwIfError(result)
    return branchRef.map { GitLocalBranch(branch: $0) }
  }
  
  public func localBranch(named name: String) -> LocalBranch?
  {
    return GitLocalBranch(repository: self, name: name)
  }
  
  public func remoteBranch(named name: String, remote: String) -> RemoteBranch?
  {
    return GitRemoteBranch(repository: self, name: "\(remote)/\(name)")
  }
  
  public func remoteBranch(named name: String) -> RemoteBranch?
  {
    return GitRemoteBranch(repository: self, name: name)
  }
  
  public func localBranch(tracking remoteBranch: RemoteBranch) -> LocalBranch?
  {
    return localBranches().first {
      $0.trackingBranchName == remoteBranch.name
    }
  }
}

extension XTRepository: BranchListing
{
  public func localBranches() -> Branches<GitLocalBranch>
  {
    return Branches(repo: self, type: GIT_BRANCH_LOCAL)
  }
  
  public func remoteBranches() -> Branches<GitRemoteBranch>
  {
    return Branches(repo: self, type: GIT_BRANCH_REMOTE)
  }
}
