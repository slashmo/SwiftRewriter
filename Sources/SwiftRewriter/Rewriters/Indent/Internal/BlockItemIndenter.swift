import SwiftSyntax

/// Adjust indents for every code-block.
class BlockItemIndenter: SyntaxRewriter, HasRewriterExamples
{
    private let _perIndent: PerIndent
    private let _shouldIndentSwitchCase: Bool
    private let _shouldIndentIfConfig: Bool
    private let _skipsCommentedLine: Bool
    private let _usesXcodeStyle: Bool

    private var _currentIndentLevel = -1

    /// Current syntax-position that tried to increment indent.
    /// - Note: This is used to not duplicate increment while traversing AST with same position.
    private var _currentPosition: AbsolutePosition? = nil

    /// Flag stack for handling `CodeBlockItemList` indent after `#if ... #endif` (`IfConfigDecl`).
    ///
    /// - Note:
    ///   - This is used when `_shouldIndentIfConfig = false`.
    ///   - Top-level is `true` because `IfConfigDecl` contains `BlockItemList` by default
    ///     which creates a new indent.
    private var _canIndentAfterIfConfig: [Bool] = [true]

    /// Method-chaining state stack.
    private var _methodChainState: [MethodChainState] = []

    var rewriterExamples: [String: String]
    {
        let i = self._perIndent.string
        let i2 = i + i

        /// Additional indent based on `_usesXcodeStyle`.
        let addition = self._usesXcodeStyle ? i : ""

        return [
            "1\n+ 2": "1\n\(i)+ 2",
            "x =\n1 + 2": "x =\n\(i)1 + 2",
            "x\n= 1 + 2": "x\n\(i)= 1 + 2",
            "let x\n= 1 + 2": "let x\n\(i)= 1 + 2",
            "let\nx = 1 + 2": "let\n\(i)x = 1 + 2",
            "var x: Int {\nreturn 1\n}": "var x: Int {\n\(i)return 1\n}",
            "func f(\nx: Int\ny:Int\n)": "func f(\n\(i)x: Int\n\(i)y:Int\n\(addition))",
            "f(\nx,\ny\n)": "f(\n\(i)x,\n\(i)y\n)",
            "f(x) {\nprint($0)}": "f(x) {\n\(i)print($0)}",
            "struct A {\nlet x: X\nvar y: Y {\nreturn why\n}\n}"
                : "struct A {\n\(i)let x: X\n\(i)var y: Y {\n\(i2)return why\n\(i)}\n}",
            "a\n.b\n.c": "a\n\(i).b\n\(i).c",
            "a\n.b()\n.c": "a\n\(i).b()\n\(i).c",
            "a\n.b\n.c()": "a\n\(i).b\n\(i).c()",
            "a\n.b()\n.c()": "a\n\(i).b()\n\(i).c()",
            "a\n.b {\n111\n}\n.c()": "a\n\(i).b {\n\(i2)111\n\(i)}\n\(i).c()",
            "a\n.b {\n111\n}\n.c {\n222\n}": "a\n\(i).b {\n\(i2)111\n\(i)}\n\(i).c {\n\(i2)222\n\(i)}",
        ]
    }

    /// - Parameters:
    ///   - skipsCommentedLine:
    ///     Skips indenting when line is commented-out, e.g. comments generated by Xcode's "Cmd + /"
    ///     (Setting `false` is same behavior as Xcode).
    ///
    ///   - usesXcodeStyle:
    ///     Mimics Xcode-style indent as best as we can :)
    init(
        perIndent: PerIndent = .spaces(4),
        shouldIndentSwitchCase: Bool = false,
        shouldIndentIfConfig: Bool = false,
        skipsCommentedLine: Bool = true,
        usesXcodeStyle: Bool = true
        )
    {
        self._perIndent = perIndent
        self._shouldIndentSwitchCase = shouldIndentSwitchCase
        self._shouldIndentIfConfig = shouldIndentIfConfig
        self._skipsCommentedLine = skipsCommentedLine
        self._usesXcodeStyle = usesXcodeStyle
    }

    /// Visit descendant using `Lens`.
    private func _visit<Whole, Part>(
        lens: Lens<Whole, Part>,
        syntax: inout Whole
        )
        where Whole: Syntax /* , Part: Syntax */
    {
        self._visit(affineTraversal: .init(lens: lens), syntax: &syntax)
    }

    /// Visit descendant using `AffineTraversal`.
    private func _visit<Whole, Part>(
        affineTraversal: AffineTraversal<Whole, Part>,
        syntax: inout Whole
        )
        where Whole: Syntax /* , Part: Syntax */
    {
        guard let part = affineTraversal.tryGet(syntax) as? Syntax else {
            return
        }

        let part2 = self.visit(part) as! Part

        if let syntax2 = affineTraversal.trySet(syntax, part2) {
            syntax = syntax2
        }
    }

    /// Increment indent level if `isIncremented == false` and `syntax` starts from newline.
    /// - SeeAlso: `_incrementIndentLevelIfNeeded(affineTraversal:...)`
    private func _incrementIndentLevelIfNeeded<Whole, Part>(
        lens: Lens<Whole, Part>,
        syntax: inout Whole,
        isIncremented: inout Bool,
        line: Int = #line
        )
        where Whole: Syntax /* , Part: Syntax */
    {
        return self._incrementIndentLevelIfNeeded(
            affineTraversal: .init(lens: lens),
            syntax: &syntax,
            isIncremented: &isIncremented,
            line: line
        )
    }

    /// Increment indent level if `isIncremented == false` and `syntax` starts from newline.
    ///
    /// - Parameters:
    ///   - isIncremented:
    ///     If initially `true`, no indent increment will occur.
    ///     This will never transit from `true` to `false`.
    ///
    /// - Note:
    /// `Part` doesn't conform to `Syntax` due to Swift limitation
    /// that can't work with existential, e.g. `Lens<_, ExprSyntax>`.
    private func _incrementIndentLevelIfNeeded<Whole, Part>(
        affineTraversal: AffineTraversal<Whole, Part>,
        syntax: inout Whole,
        isIncremented: inout Bool,
        line: Int = #line
        )
        where Whole: Syntax /* , Part: Syntax */
    {
        guard let part = affineTraversal.tryGet(syntax) as? Syntax else {
            return
        }

        Debug.print("""
            ========================================
            [tryIndent] \(type(of: syntax)) > \(type(of: part))
            [tryIndent] newPosition = \(part.position)
            [tryIndent] oldPosition = \(self._currentPosition.map(String.init(describing:)) ?? "nil")
            [tryIndent] part.leadingTriviaLength.newlines > 0 = \(part.leadingTriviaLength.newlines > 0)
            [tryIndent] isIncremented = \(isIncremented)
            "\(part.shortDebugString)"
            ========================================
            """)

        // If newline detected and not already indented
        if !isIncremented
            && (part.leadingTriviaLength.newlines > 0 || part.containsFirstToken)
            && part.position != self._currentPosition
        {
            isIncremented = true

            self._incrementIndentLevel(tag: syntax, line: line)
        }

        self._currentPosition = part.position

        let part2 = self.visit(part) as! Part

        if let syntax2 = affineTraversal.trySet(syntax, part2) {
            syntax = syntax2
        }
    }

    /// - Important: Do not use this method directly. Use `_incrementIndentLevelIfNeeded` instead.
    private func _incrementIndentLevel<T: Syntax>(
        tag syntax: @autoclosure () -> T,
        line: Int = #line
        )
    {
        let syntax = syntax()

        Debug.print("""
            ========================================
            [indent] incr+++ \(type(of: syntax)), line \(line)
            \(syntax.shortDebugString)
            ========================================
            """)

        self._currentIndentLevel += 1
    }

    private func _decrementIndentLevel<T: Syntax>(
        tag syntax: @autoclosure () -> T,
        line: Int = #line
        )
    {
        let syntax = syntax()

        Debug.print("""
            ========================================
            [indent] decr--- \(type(of: syntax)), line \(line)
            \(syntax.shortDebugString)
            ========================================
            """)

        self._currentIndentLevel -= 1
    }

    // MARK: - ListSyntax

    // MARK: IfConfigClauseListSyntax

    override func visit(_ syntax: IfConfigClauseListSyntax) -> Syntax
    {
        if !self._shouldIndentIfConfig {
            self._canIndentAfterIfConfig.append(false)
        }

        defer {
            if !self._shouldIndentIfConfig {
                self._canIndentAfterIfConfig.removeLast()
            }
        }

        // NOTE: Don't use `_visitChildrenAndIndentIfNeeded` because indent is not needed.
        return super.visit(syntax)
    }

    // MARK: CodeBlockItemListSyntax

    override func visit(_ syntax: CodeBlockItemListSyntax) -> Syntax
    {
        let canIndent = self._canIndentAfterIfConfig.last == true

        if !canIndent {
            self._canIndentAfterIfConfig.append(true)
        }

        defer {
            if !canIndent {
                self._canIndentAfterIfConfig.removeLast()
            }
        }

        return self._visitChildrenAndIndentIfNeeded(syntax, canIndent: canIndent)
    }

    // MARK: MemberDeclListSyntax

    // Increment indent level when `struct Foo {\nlet ...`.
    override func visit(_ syntax: MemberDeclListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: ExprListSyntax

    override func visit(_ syntax: ExprListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: PatternBindingListSyntax

    override func visit(_ syntax: PatternBindingListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: AccessorListSyntax

    // e.g. computed property's `get`/`set`.
    override func visit(_ syntax: AccessorListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: ConditionElementListSyntax

    // e.g. `if true,\ntrue {`
    override func visit(_ syntax: ConditionElementListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: FunctionParameterListSyntax

    // Increment indent level after `func foo(`.
    override func visit(_ syntax: FunctionParameterListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: GenericParameterListSyntax

    override func visit(_ syntax: GenericParameterListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: GenericArgumentListSyntax

    override func visit(_ syntax: GenericArgumentListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: GenericRequirementListSyntax

    override func visit(_ syntax: GenericRequirementListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: InheritedTypeListSyntax

    override func visit(_ syntax: InheritedTypeListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: TuplePatternElementListSyntax

    override func visit(_ syntax: TuplePatternElementListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: TupleTypeElementListSyntax

    override func visit(_ syntax: TupleTypeElementListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: TupleElementListSyntax

    override func visit(_ syntax: TupleElementListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: ArrayElementListSyntax

    override func visit(_ syntax: ArrayElementListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: DictionaryElementListSyntax

    override func visit(_ syntax: DictionaryElementListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: SwitchCaseListSyntax

    override func visit(_ syntax: SwitchCaseListSyntax) -> Syntax
    {
        if self._shouldIndentSwitchCase {
            return self._visitChildrenAndIndentIfNeeded(syntax)
        }
        else {
            return super.visit(syntax)
        }
    }

    // MARK: CaseItemListSyntax

    override func visit(_ syntax: CaseItemListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: PrecedenceGroupAttributeListSyntax

    override func visit(_ syntax: PrecedenceGroupAttributeListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    // MARK: FunctionCallArgumentListSyntax

    // Increment indent level after `doSomthing(`.
    override func visit(_ syntax: FunctionCallArgumentListSyntax) -> Syntax
    {
        return self._visitChildrenAndIndentIfNeeded(syntax)
    }

    /// Visit children to try indent increment (at most 1).
    private func _visitChildrenAndIndentIfNeeded<T>(_ syntax: T, canIndent: Bool = true, line: Int = #line) -> T
        where T: SyntaxCollection
    {
        /// - Note: This flag will become from `false` to `true` at most once.
        var isIncremented: Bool = !canIndent

        var syntax2: T = syntax

        for i in syntax.indices {
            self._methodChainState.append(.initialized)

            defer {
                self._methodChainState.removeLast()
            }

            self._incrementIndentLevelIfNeeded(
                lens: .child(at: i),
                syntax: &syntax2,
                isIncremented: &isIncremented,
                line: line
            )
        }

        if canIndent && isIncremented {
            self._decrementIndentLevel(tag: syntax, line: line)
        }

        return syntax2
    }

    // MARK: - DeclSyntax

    // MARK: InitializerDeclSyntax

    override func visit(_ syntax: InitializerDeclSyntax) -> DeclSyntax
    {
        var syntax2 = syntax
        var isIncremented: Bool = false

        self._visit(lens: .attributes, syntax: &syntax2)
        self._visit(lens: .modifiers, syntax: &syntax2)
        self._visit(lens: .initKeyword, syntax: &syntax2)
        self._visit(lens: .optionalMark, syntax: &syntax2)
        self._visit(lens: .genericParameterClause, syntax: &syntax2)
        self._visit(lens: .parameters >>> .leftParen, syntax: &syntax2)
        self._visit(lens: .parameters >>> .parameterList, syntax: &syntax2)

        self._incrementIndentLevelIfNeeded(
            lens: .parameters >>> .rightParen,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .throwsOrRethrowsKeyword,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .genericWhereClause,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        if isIncremented {
            self._decrementIndentLevel(tag: syntax)
        }

        self._visit(lens: .body, syntax: &syntax2)

        return syntax2
    }

    // MARK: FunctionDeclSyntax

    override func visit(_ syntax: FunctionDeclSyntax) -> DeclSyntax
    {
        var syntax2 = syntax
        var isIncremented: Bool = false

        self._visit(lens: .attributes, syntax: &syntax2)
        self._visit(lens: .modifiers, syntax: &syntax2)
        self._visit(lens: .funcKeyword, syntax: &syntax2)
        self._visit(lens: .identifier, syntax: &syntax2)
        self._visit(lens: .genericParameterClause, syntax: &syntax2)
        self._visit(lens: .signature, syntax: &syntax2)

        self._incrementIndentLevelIfNeeded(
            lens: .genericWhereClause,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        if isIncremented {
            self._decrementIndentLevel(tag: syntax)
        }

        self._visit(lens: .body, syntax: &syntax2)

        return syntax2
    }

    // MARK: FunctionSignatureSyntax

    override func visit(_ syntax: FunctionSignatureSyntax) -> Syntax
    {
        var syntax2 = syntax
        var isIncremented: Bool = false

        self._incrementIndentLevelIfNeeded(
            lens: .input >>> .leftParen,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._visit(lens: .input >>> .parameterList, syntax: &syntax2)

        if self._usesXcodeStyle {
            // Indent `func foo(\n)->Int` like Xcode does.
            self._incrementIndentLevelIfNeeded(
                lens: .input >>> .rightParen,
                syntax: &syntax2,
                isIncremented: &isIncremented
            )
        }
        else {
            self._visit(lens: .input >>> .rightParen, syntax: &syntax2)
        }

        self._incrementIndentLevelIfNeeded(
            lens: .throwsOrRethrowsKeyword,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        // Indent `func foo()\n->Int`.
        self._incrementIndentLevelIfNeeded(
            lens: .output,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        if isIncremented {
            self._decrementIndentLevel(tag: syntax)
        }

        return syntax2
    }

    // MARK: - StmtSyntax

    // MARK: GuardStmtSyntax

    // Indent `guard ... \nelse`.
    override func visit(_ syntax: GuardStmtSyntax) -> StmtSyntax
    {
        var syntax2 = syntax
        var isIncremented: Bool = false

        syntax2 = syntax2.withGuardKeyword(self.visit(syntax2.guardKeyword) as? TokenSyntax)
        syntax2 = syntax2.withConditions(self.visit(syntax2.conditions) as? ConditionElementListSyntax)

        self._incrementIndentLevelIfNeeded(
            lens: .elseKeyword,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .body,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        if isIncremented {
            self._decrementIndentLevel(tag: syntax)
        }

        return syntax2
    }

    // MARK: - ClauseSyntax

    // MARK: InitializerClauseSyntax

    // For working with `let x\n=1 + 2` (`let` binding with '\n' before assignment).
    override func visit(_ syntax: InitializerClauseSyntax) -> Syntax
    {
        var syntax2 = syntax
        var isIncremented: Bool = false

        self._incrementIndentLevelIfNeeded(
            lens: .equal,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .value,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        if isIncremented {
            self._decrementIndentLevel(tag: syntax)
        }

        return syntax2
    }

    override func visit(_ syntax: WhereClauseSyntax) -> Syntax
    {
        var syntax2 = syntax
        var isIncremented: Bool = false

        self._incrementIndentLevelIfNeeded(
            lens: .whereKeyword,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .guardResult,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        if isIncremented {
            self._decrementIndentLevel(tag: syntax)
        }

        return syntax2
    }

    // MARK: - ExprSyntax

    // MARK: TernaryExprSyntax

    // Indent e.g. `flag\n?true\n:false` (after `conditionExpression`).
    override func visit(_ syntax: TernaryExprSyntax) -> ExprSyntax
    {
        var syntax2 = syntax
        var isIncremented = false

        syntax2 = syntax2.withConditionExpression(
            self.visit(syntax2.conditionExpression) as? ExprSyntax
        )

        self._incrementIndentLevelIfNeeded(
            lens: .questionMark,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .firstChoice,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .colonMark,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        self._incrementIndentLevelIfNeeded(
            lens: .secondChoice,
            syntax: &syntax2,
            isIncremented: &isIncremented
        )

        if isIncremented {
            self._decrementIndentLevel(tag: syntax)
        }

        return syntax2
    }

    // MARK: Adjust method chaining indent

    // MARK: FunctionCallExprSyntax

    override func visit(_ syntax: FunctionCallExprSyntax) -> ExprSyntax
    {
        var syntax2 = syntax

        let isInitialized = self._methodChainState.last == .initialized

        // Set to `.detected` if possible.
        if isInitialized {
            self._methodChainState.updateLast(.detected(syntax: syntax, isIncremented: false))
        }

        syntax2 = super.visit(syntax2) as! FunctionCallExprSyntax

        // Decrement indent if detected at this visit.
        if case let .detected(syntax_, isIncremented)? = self._methodChainState.last,
            syntax_ == syntax
        {
            if isIncremented {
                self._decrementIndentLevel(tag: syntax)
            }
        }

        return syntax2
    }

    // MARK: MemberAccessExprSyntax

    // Increment method-chaining's `dot` indent (for property access, not function call).
    override func visit(_ syntax: MemberAccessExprSyntax) -> ExprSyntax
    {
        var syntax2 = syntax

        // Set to `.detected` if possible.
        if self._methodChainState.last == .initialized {
            self._methodChainState.updateLast(.detected(syntax: syntax, isIncremented: false))
        }

        // If `foo.bar().baz` ...
        if var funcCall = syntax2.base as? FunctionCallExprSyntax,
            let memberAccess2 = funcCall.calledExpression as? MemberAccessExprSyntax
        {
            // Visit grandchild `MemberAccessExprSyntax`.
            funcCall = funcCall.withCalledExpression(self.visit(memberAccess2))

            self._visit(lens: .leftParen, syntax: &funcCall)
            self._visit(lens: .argumentList, syntax: &funcCall)

            var isIncremented: Bool = self._methodChainState.last!.isIncremented!

            if self._usesXcodeStyle {

                // Try indent on `)`.
                self._incrementIndentLevelIfNeeded(
                    lens: .rightParen,
                    syntax: &funcCall,
                    isIncremented: &isIncremented
                )

                let trailingClosure =
                    Lens<FunctionCallExprSyntax, ClosureExprSyntax?>.trailingClosure
                        >>> some()

                self._visit(affineTraversal: trailingClosure >>> .leftBrace, syntax: &funcCall)
                self._visit(affineTraversal: trailingClosure >>> .signature, syntax: &funcCall)
                self._visit(affineTraversal: trailingClosure >>> .statements, syntax: &funcCall)

                // Try indent on `}`.
                self._incrementIndentLevelIfNeeded(
                    affineTraversal: trailingClosure >>> .rightBrace,
                    syntax: &funcCall,
                    isIncremented: &isIncremented
                )
            }
            else {
                self._visit(lens: .rightParen, syntax: &funcCall)
                self._visit(lens: .trailingClosure, syntax: &funcCall)
            }

            syntax2 = syntax2.withBase(funcCall)

            self._incrementIndentLevelIfNeeded(
                lens: .dot,
                syntax: &syntax2,
                isIncremented: &isIncremented
            )

            if isIncremented {
                self._methodChainState.updateLast(self._methodChainState.last!.incrementedState!)
            }

            self._visit(lens: .name, syntax: &syntax2)
            self._visit(lens: .declNameArguments, syntax: &syntax2)
        }
        // If `foo.bar.baz` or `foo.bar` (no more method-chain) ...
        else {
            // Visit child `MemberAccessExprSyntax`.
            self._visit(lens: .base, syntax: &syntax2)

            var isIncremented: Bool = self._methodChainState.last!.isIncremented!

            self._incrementIndentLevelIfNeeded(
                lens: .dot,
                syntax: &syntax2,
                isIncremented: &isIncremented
            )

            if isIncremented {
                self._methodChainState.updateLast(self._methodChainState.last!.incrementedState!)
            }

            self._visit(lens: .name, syntax: &syntax2)
            self._visit(lens: .declNameArguments, syntax: &syntax2)
        }

        // Decrement indent if detected at this visit.
        if case let .detected(syntax_, isIncremented)? = self._methodChainState.last,
            syntax_ == syntax
        {
            if isIncremented {
                self._decrementIndentLevel(tag: syntax)
            }
        }

        return syntax2
    }

    // MARK: - TokenSyntax

    override func visit(_ token: TokenSyntax) -> Syntax
    {
        // Workaround for indenting comment that is closing symbol's leadingTrivia,
        // e.g. `func foo() {\n// comment\n}`.
        if token.tokenKind.isClosingSymbol
            || (self._shouldIndentIfConfig
                && (token.tokenKind == .poundElseKeyword
                    || token.tokenKind == .poundElseKeyword
                    || token.tokenKind == .poundEndifKeyword))
        {
            let token2 = token.withIndent(
                strategy: self._indentStrategy(adjustsLeadingTriviaComment: true)
            )
            return super.visit(token2)
        }

        let token2 = token.withIndent(strategy: self._indentStrategy())
        return super.visit(token2)
    }

    // MARK: - Private

    private func _indentStrategy(
        level: Int? = nil,
        adjustsLeadingTriviaComment: Bool = false
        ) -> IndentStrategy
    {
        return IndentStrategy.useIndent(
            indent: Indent(
                level: level ?? self._currentIndentLevel,
                perIndent: self._perIndent
            ),
            skipsCommentedLine: self._skipsCommentedLine,
            adjustsLeadingTriviaComment: adjustsLeadingTriviaComment
        )
    }
}

// MARK: - MethodChainState

private enum MethodChainState: Equatable
{
    /// Created when visiting `SyntaxCollection`'s children.
    case initialized

    /// Created after `.initialized` when visiting "method-chain"
    /// i.e. `FunctionCallExprSyntax` or `MemberAccessExprSyntax`.
    case detected(syntax: Syntax, isIncremented: Bool)

    var isIncremented: Bool?
    {
        switch self {
        case .initialized:
            return nil
        case let .detected(_, isIncremented):
            return isIncremented
        }
    }

    var incrementedState: MethodChainState?
    {
        switch self {
        case .initialized:
            return nil
        case let .detected(syntax, _):
            return .detected(syntax: syntax, isIncremented: true)
        }
    }

    static func == (l: MethodChainState, r: MethodChainState) -> Bool {
        switch (l, r) {
        case (.initialized, .initialized):
            return true
        case let (.detected(s1, is1), .detected(s2, is2)):
            return s1 == s2 && is1 == is2
        default:
            return false
        }
    }

}