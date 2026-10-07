package cjdist

public func reportOk(area: String, message: String): Unit {
    println("OK    ${area}    ${message}")
}

public func reportError(area: String, message: String): Unit {
    eprintln("ERROR ${area}    ${message}")
}
