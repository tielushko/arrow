# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

#' Write a dataset
#'
#' This function allows you to write a dataset. By writing to more efficient
#' binary storage formats, and by specifying relevant partitioning, you can
#' make it much faster to read and query.
#'
#' @param dataset [Dataset], [RecordBatch], [Table], `arrow_dplyr_query`, or
#' `data.frame`. If an `arrow_dplyr_query`, the query will be evaluated and
#' the result will be written. This means that you can `select()`, `filter()`, `mutate()`,
#' etc. to transform the data before it is written if you need to.
#' @param path string path, URI, or `SubTreeFileSystem` referencing a directory
#' to write to (directory will be created if it does not exist)
#' @param format a string identifier of the file format. Default is to use
#' "parquet" (see [FileFormat])
#' @param partitioning `Partitioning` or a character vector of columns to
#' use as partition keys (to be written as path segments). Default is to
#' use the current `group_by()` columns.
#' @param basename_template string template for the names of files to be written.
#' Must contain `"{i}"`, which will be replaced with an autoincremented
#' integer to generate basenames of datafiles. For example, `"part-{i}.feather"`
#' will yield `"part-0.feather", ...`.
#' @param hive_style logical: write partition segments as Hive-style
#' (`key1=value1/key2=value2/file.ext`) or as just bare values. Default is `TRUE`.
#' @param existing_data_behavior The behavior to use when there is already data
#' in the destination directory.  Must be one of "overwrite", "error", or
#' "delete_matching".
#' - "overwrite" (the default) then any new files created will overwrite
#'   existing files
#' - "error" then the operation will fail if the destination directory is not
#'   empty
#' - "delete_matching" then the writer will delete any existing partitions
#'   if data is going to be written to those partitions and will leave alone
#'   partitions which data is not written to.
#' @param max_partitions maximum number of partitions any batch may be
#' written into. Default is 1024L.
#' @param ... additional format-specific arguments. For available Parquet
#' options, see [write_parquet()]. The available Feather options are
#' - `use_legacy_format` logical: write data formatted so that Arrow libraries
#'   versions 0.14 and lower can read it. Default is `FALSE`. You can also
#'   enable this by setting the environment variable `ARROW_PRE_0_15_IPC_FORMAT=1`.
#' - `metadata_version`: A string like "V5" or the equivalent integer indicating
#'   the Arrow IPC MetadataVersion. Default (NULL) will use the latest version,
#'   unless the environment variable `ARROW_PRE_1_0_METADATA_VERSION=1`, in
#'   which case it will be V4.
#' - `codec`: A [Codec] which will be used to compress body buffers of written
#'   files. Default (NULL) will not compress body buffers.
#' - `null_fallback`: character to be used in place of missing values (`NA` or
#' `NULL`) when using Hive-style partitioning. See [hive_partition()].
#' @return The input `dataset`, invisibly
#' @examplesIf arrow_with_dataset() & arrow_with_parquet() & requireNamespace("dplyr", quietly = TRUE)
#' # You can write datasets partitioned by the values in a column (here: "cyl").
#' # This creates a structure of the form cyl=X/part-Z.parquet.
#' one_level_tree <- tempfile()
#' write_dataset(mtcars, one_level_tree, partitioning = "cyl")
#' list.files(one_level_tree, recursive = TRUE)
#'
#' # You can also partition by the values in multiple columns
#' # (here: "cyl" and "gear").
#' # This creates a structure of the form cyl=X/gear=Y/part-Z.parquet.
#' two_levels_tree <- tempfile()
#' write_dataset(mtcars, two_levels_tree, partitioning = c("cyl", "gear"))
#' list.files(two_levels_tree, recursive = TRUE)
#'
#' # In the two previous examples we would have:
#' # X = {4,6,8}, the number of cylinders.
#' # Y = {3,4,5}, the number of forward gears.
#' # Z = {0,1,2}, the number of saved parts, starting from 0.
#'
#' # You can obtain the same result as as the previous examples using arrow with
#' # a dplyr pipeline. This will be the same as two_levels_tree above, but the
#' # output directory will be different.
#' library(dplyr)
#' two_levels_tree_2 <- tempfile()
#' mtcars %>%
#'   group_by(cyl, gear) %>%
#'   write_dataset(two_levels_tree_2)
#' list.files(two_levels_tree_2, recursive = TRUE)
#'
#' # And you can also turn off the Hive-style directory naming where the column
#' # name is included with the values by using `hive_style = FALSE`.
#'
#' # Write a structure X/Y/part-Z.parquet.
#' two_levels_tree_no_hive <- tempfile()
#' mtcars %>%
#'   group_by(cyl, gear) %>%
#'   write_dataset(two_levels_tree_no_hive, hive_style = FALSE)
#' list.files(two_levels_tree_no_hive, recursive = TRUE)
#' @export
write_dataset <- function(dataset,
                          path,
                          format = c("parquet", "feather", "arrow", "ipc", "csv"),
                          partitioning = dplyr::group_vars(dataset),
                          basename_template = paste0("part-{i}.", as.character(format)),
                          hive_style = TRUE,
                          existing_data_behavior = c("overwrite", "error", "delete_matching"),
                          max_partitions = 1024L,
                          ...) {
  format <- match.arg(format)
  if (inherits(dataset, "arrow_dplyr_query")) {
    # partitioning vars need to be in the `select` schema
    dataset <- ensure_group_vars(dataset)
  } else if (inherits(dataset, "grouped_df")) {
    force(partitioning)
    # Drop the grouping metadata before writing; we've already consumed it
    # now to construct `partitioning` and don't want it in the metadata$r
    dataset <- dplyr::ungroup(dataset)
  }

  scanner <- Scanner$create(dataset, use_async = TRUE)
  if (!inherits(partitioning, "Partitioning")) {
    partition_schema <- scanner$schema[partitioning]
    if (isTRUE(hive_style)) {
      partitioning <- HivePartitioning$create(partition_schema, null_fallback = list(...)$null_fallback)
    } else {
      partitioning <- DirectoryPartitioning$create(partition_schema)
    }
  }

  path_and_fs <- get_path_and_filesystem(path)
  options <- FileWriteOptions$create(format, table = scanner, ...)

  existing_data_behavior_opts <- c("delete_matching", "overwrite", "error")
  existing_data_behavior <- match(match.arg(existing_data_behavior), existing_data_behavior_opts) - 1L

  if (!is_integerish(max_partitions, n = 1) || is.na(max_partitions) || max_partitions < 0) {
    abort("max_partitions must be a positive, non-missing integer")
  }

  dataset___Dataset__Write(
    options, path_and_fs$fs, path_and_fs$path,
    partitioning, basename_template, scanner,
    existing_data_behavior, max_partitions
  )
}
