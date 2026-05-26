package = "MoneyMoney"
version = "dev-1"
source = {
   url = "*** please add URL for source tarball, zip or repository here ***"
}
description = {
   homepage = "*** please enter a project homepage ***",
   license = "*** please specify a license ***"
}
dependencies = {
   "lua >= 5.1, < 5.5"
}
build = {
   type = "builtin",
   modules = {
      AddikoAustria = "AddikoAustria.lua",
      Debug = "Debug.lua",
      Fidelity = "Fidelity.lua",
      ["Fidelity NetBenefits"] = "Fidelity NetBenefits.lua",
      ["Presidential Bank"] = "Presidential Bank.lua"
   }
}
