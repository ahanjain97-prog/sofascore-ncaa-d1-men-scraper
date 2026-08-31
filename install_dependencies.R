#!/usr/bin/env Rscript

packages <- c("chromote", "data.table", "httr2", "jsonlite")
user_library <- path.expand(Sys.getenv("R_LIBS_USER"))
if (!nzchar(user_library)) {
  user_library <- file.path(path.expand("~"), "R", "library")
}
if (!dir.exists(user_library)) dir.create(user_library, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(user_library, .libPaths()))

installed <- rownames(installed.packages())
missing <- setdiff(packages, installed)

if (!length(missing)) {
  message("All required packages are already installed.")
  quit(status = 0L, save = "no")
}

message("Installing: ", paste(missing, collapse = ", "))
install.packages(missing, repos = "https://cloud.r-project.org", lib = user_library)

still_missing <- missing[!vapply(missing, requireNamespace, logical(1L), quietly = TRUE)]
if (length(still_missing)) {
  stop("Installation failed for: ", paste(still_missing, collapse = ", "), call. = FALSE)
}

message("Dependencies installed successfully.")
