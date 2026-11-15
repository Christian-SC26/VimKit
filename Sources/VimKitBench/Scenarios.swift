/// One measured operation: `setup` and `between` are not timed, `keys` is
/// timed once per repeat. `between` runs after every repeat but the last
/// (usually `u`, so each repeat starts from the same text).
struct Scenario: Sendable {
    let category: String
    let name: String
    var setup: String = ""
    let keys: String
    var between: String = ""
    var repeats: Int
}

/// Code-like sample text: blocks of 10 lines with nested braces, quotes,
/// brackets and indentation (for folds, `%`, text objects and `=`).
/// About 37 characters per line on average.
func sampleCode(lines: Int) -> String {
    var result: [String] = []
    result.reserveCapacity(lines)
    var block = 0
    while result.count < lines {
        let i = block
        result += [
            "func handler\(i)(value: Int) -> Int {",
            "    let value\(i) = compute(\(i), \"label \(i)\") // note \(i % 97)",
            "    if value\(i) > \(i % 50) {",
            "        print(\"item \(i)\", value\(i))",
            "        total += value\(i) * (\(i) + 1)",
            "    }",
            "    var list\(i) = [\(i), \(i + 1), \(i + 2)]",
            "    return list\(i).count + value\(i)",
            "}",
            "",
        ]
        block += 1
    }
    return result.prefix(lines).joined(separator: "\n")
}

// Cursor positions in the middle of the document. `50%` lands on the empty
// line that ends a block, so `50%j` is the `func` line of the next block.
private let fn = "50%j"          // func handler(value: Int) -> Int {
private let letLine = "50%jj"    //     let value = compute(i, "label i") // note
private let ifLine = "50%j2j"    //     if value > n {
private let listLine = "50%j6j"  //     var list = [i, i+1, i+2]

let scenarios: [Scenario] = [
    .init(category: "Стенд", name: "пустая операция (накладные расходы)", keys: "", repeats: 200),

    // Motions
    .init(category: "Движения", name: "j", keys: "j", repeats: 200),
    .init(category: "Движения", name: "k", setup: "G", keys: "k", repeats: 200),
    .init(category: "Движения", name: "w", keys: "w", repeats: 200),
    .init(category: "Движения", name: "b", setup: "G$", keys: "b", repeats: 200),
    .init(category: "Движения", name: "e", keys: "e", repeats: 200),
    .init(category: "Движения", name: "W", keys: "W", repeats: 200),
    .init(category: "Движения", name: "$ и 0", setup: letLine, keys: "$0", repeats: 100),
    .init(category: "Движения", name: "^", setup: letLine, keys: "^", repeats: 100),
    .init(category: "Движения", name: "f(", setup: letLine, keys: "0f(", repeats: 100),
    .init(category: "Движения", name: "t\"", setup: letLine, keys: "0t\"", repeats: 100),
    .init(category: "Движения", name: "%", setup: "gg$", keys: "%", repeats: 100),
    .init(category: "Движения", name: "}", keys: "}", repeats: 100),
    .init(category: "Движения", name: "{", setup: "G", keys: "{", repeats: 100),
    .init(category: "Движения", name: "G и gg", keys: "Ggg", repeats: 10),
    .init(category: "Движения", name: "50%", keys: "50%", between: "gg", repeats: 20),
    .init(category: "Движения", name: "<C-d>", keys: "<C-d>", repeats: 50),
    .init(category: "Движения", name: "<C-u>", setup: "G", keys: "<C-u>", repeats: 50),
    .init(category: "Движения", name: "<C-f>", keys: "<C-f>", repeats: 50),
    .init(category: "Движения", name: "<C-b>", setup: "G", keys: "<C-b>", repeats: 50),
    .init(category: "Движения", name: "gj", keys: "gj", repeats: 100),
    .init(category: "Движения", name: "L и H", setup: fn, keys: "LH", repeats: 50),
    .init(category: "Движения", name: "zz", setup: fn, keys: "jzz", repeats: 50),
    .init(category: "Движения", name: "метка: gg 'a", setup: fn + "ma", keys: "gg'a", repeats: 50),

    // Search
    .init(category: "Поиск", name: "/шаблон<CR>", keys: "/label 77<CR>", repeats: 10),
    .init(category: "Поиск", name: "?шаблон<CR>", setup: "G", keys: "?note 13<CR>", repeats: 10),
    .init(category: "Поиск", name: "n", setup: "/note 5<CR>", keys: "n", repeats: 100),
    .init(category: "Поиск", name: "N", setup: "G/note 5<CR>", keys: "N", repeats: 100),
    .init(category: "Поиск", name: "*", setup: letLine + "w", keys: "*", repeats: 20),
    .init(category: "Поиск", name: "#", setup: letLine + "w", keys: "#", repeats: 20),

    // Operators
    .init(category: "Операторы", name: "x", setup: letLine, keys: "x", between: "u", repeats: 100),
    .init(category: "Операторы", name: "dd", setup: fn, keys: "dd", repeats: 50),
    .init(category: "Операторы", name: "3dd", setup: fn, keys: "3dd", repeats: 30),
    .init(category: "Операторы", name: "dw", setup: letLine, keys: "dw", between: "u", repeats: 50),
    .init(category: "Операторы", name: "D", setup: letLine, keys: "D", between: "u", repeats: 50),
    .init(category: "Операторы", name: "J", setup: letLine, keys: "J", between: "u", repeats: 50),
    .init(category: "Операторы", name: "yy", setup: letLine, keys: "yy", repeats: 100),
    .init(category: "Операторы", name: "p (строка)", setup: letLine + "yy", keys: "p", repeats: 50),
    .init(category: "Операторы", name: "P (строка)", setup: letLine + "yy", keys: "P", repeats: 50),
    .init(category: "Операторы", name: ">>", setup: letLine, keys: ">>", repeats: 50),
    .init(category: "Операторы", name: "<<", setup: letLine + ">>>>>>", keys: "<lt><lt>", between: ">>", repeats: 50),
    .init(category: "Операторы", name: "~", setup: letLine, keys: "~", repeats: 100),
    .init(category: "Операторы", name: "gUiw", setup: letLine + "w", keys: "gUiw", between: "u", repeats: 50),
    .init(category: "Операторы", name: "guu", setup: letLine, keys: "guu", between: "u", repeats: 50),
    .init(category: "Операторы", name: "r", setup: letLine, keys: "rx", between: "u", repeats: 50),
    .init(category: "Операторы", name: "cc", setup: letLine, keys: "ccnew line<Esc>", between: "u", repeats: 50),
    .init(category: "Операторы", name: "ciw", setup: letLine + "w", keys: "ciwabc<Esc>", between: "u", repeats: 50),
    .init(category: "Операторы", name: ". (повтор ciw)", setup: letLine + "wciwabc<Esc>j", keys: ".j", repeats: 50),
    .init(category: "Операторы", name: "==", setup: letLine, keys: "==", repeats: 50),

    // Text objects
    .init(category: "Текстовые объекты", name: "diw", setup: letLine + "w", keys: "diw", between: "u", repeats: 50),
    .init(category: "Текстовые объекты", name: "daw", setup: letLine + "w", keys: "daw", between: "u", repeats: 50),
    .init(category: "Текстовые объекты", name: "ci\"", setup: letLine + "0f\"", keys: "ci\"abc<Esc>", between: "u", repeats: 50),
    .init(category: "Текстовые объекты", name: "di(", setup: letLine + "0f(l", keys: "di(", between: "u", repeats: 50),
    .init(category: "Текстовые объекты", name: "ca[", setup: listLine + "0f[l", keys: "ca[x<Esc>", between: "u", repeats: 50),
    .init(category: "Текстовые объекты", name: "di{", setup: ifLine + "j", keys: "di{", between: "u", repeats: 50),
    .init(category: "Текстовые объекты", name: "yap", setup: letLine, keys: "yap", repeats: 50),
    .init(category: "Текстовые объекты", name: "dap", setup: letLine, keys: "dap", between: "u", repeats: 30),

    // Visual mode
    .init(category: "Визуальный режим", name: "vjjy", setup: fn, keys: "vjjy", repeats: 50),
    .init(category: "Визуальный режим", name: "Vjj>", setup: fn, keys: "Vjj>", between: "u", repeats: 50),
    .init(category: "Визуальный режим", name: "<C-v>4jI// <Esc>", setup: fn, keys: "<C-v>4jI// <Esc>", between: "u", repeats: 30),
    .init(category: "Визуальный режим", name: "VGy (весь файл)", setup: "gg", keys: "VGy", between: "gg", repeats: 3),
    .init(category: "Визуальный режим", name: "ggVG> (весь файл)", keys: "ggVG>", between: "u", repeats: 2),
    .init(category: "Визуальный режим", name: "ggVG= (весь файл)", keys: "ggVG=", between: "u", repeats: 2),

    // Insert mode
    .init(category: "Ввод текста", name: "набор символа", setup: fn + "i", keys: "a", repeats: 200),
    .init(category: "Ввод текста", name: "Enter в insert", setup: fn + "A", keys: "<CR>", repeats: 50),
    .init(category: "Ввод текста", name: "Backspace в insert", setup: letLine + "A", keys: "<BS>", repeats: 50),
    .init(category: "Ввод текста", name: "o<Esc>", setup: fn, keys: "o<Esc>", repeats: 50),
    .init(category: "Ввод текста", name: "A;<Esc>", setup: fn, keys: "A;<Esc>j", repeats: 50),

    // Undo
    .init(category: "Отмена", name: "u (одна правка)", setup: letLine + String(repeating: "x", count: 50), keys: "u", repeats: 50),
    .init(category: "Отмена", name: "<C-r>", setup: letLine + String(repeating: "x", count: 50) + String(repeating: "u", count: 50),
          keys: "<C-r>", repeats: 50),
    .init(category: "Отмена", name: "u после :%s", setup: ":%s/value/item/g<CR>", keys: "u", between: "<C-r>", repeats: 3),

    // Ex commands
    .init(category: "Ex-команды", name: ":%s/value/item/g", keys: ":%s/value/item/g<CR>", between: "u", repeats: 3),
    .init(category: "Ex-команды", name: ":%s без совпадений", keys: ":%s/zzzz/q/ge<CR>", repeats: 3),
    .init(category: "Ex-команды", name: ":g/note 5/d", keys: ":g/note 5/d<CR>", between: "u", repeats: 3),
    .init(category: "Ex-команды", name: ":sort", keys: ":sort<CR>", between: "u", repeats: 3),
    .init(category: "Ex-команды", name: ":10,200d", keys: ":10,200d<CR>", between: "u", repeats: 10),
    .init(category: "Ex-команды", name: ":%norm A;", keys: ":%norm A;<CR>", between: "u", repeats: 2),

    // Registers and macros
    .init(category: "Регистры и макросы", name: "\"ayy", setup: fn, keys: "\"ayy", repeats: 50),
    .init(category: "Регистры и макросы", name: "\"ap", setup: fn + "\"ayy", keys: "\"ap", repeats: 50),
    .init(category: "Регистры и макросы", name: "@a (макрос A;<Esc>j)", setup: fn + "qaA;<Esc>jq", keys: "@a", repeats: 50),
    .init(category: "Регистры и макросы", name: "100@a", setup: "ggqaA;<Esc>jq", keys: "100@a", between: "gg", repeats: 3),

    // Folds
    .init(category: "Свёртки", name: "zM (свернуть всё)", keys: "zM", between: "zR", repeats: 5),
    .init(category: "Свёртки", name: "zR (развернуть всё)", setup: "zM", keys: "zR", between: "zM", repeats: 5),
    .init(category: "Свёртки", name: "za", setup: fn, keys: "za", repeats: 50),
    .init(category: "Свёртки", name: "j по свёрнутым блокам", setup: "zM", keys: "j", repeats: 200),
    .init(category: "Свёртки", name: "zf3j", setup: fn, keys: "zf3j", between: "zd", repeats: 30),
]
