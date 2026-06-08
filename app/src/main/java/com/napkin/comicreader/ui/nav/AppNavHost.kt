package com.napkin.comicreader.ui.nav

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.napkin.comicreader.ComicReaderApp
import com.napkin.comicreader.ui.library.LibraryScreen
import com.napkin.comicreader.ui.library.LibraryViewModel
import com.napkin.comicreader.ui.reader.ReaderScreen
import com.napkin.comicreader.ui.reader.ReaderViewModel

private object Routes {
    const val LIBRARY = "library"
    const val READER = "reader/{comicId}"
    fun reader(comicId: Long) = "reader/$comicId"
}

@Composable
fun AppNavHost() {
    val navController = rememberNavController()
    val app = LocalContext.current.applicationContext as ComicReaderApp

    NavHost(navController = navController, startDestination = Routes.LIBRARY) {
        composable(Routes.LIBRARY) {
            val vm: LibraryViewModel = viewModel(factory = LibraryViewModel.factory(app))
            LibraryScreen(
                viewModel = vm,
                onOpenComic = { id -> navController.navigate(Routes.reader(id)) },
            )
        }
        composable(
            route = Routes.READER,
            arguments = listOf(navArgument("comicId") { type = NavType.LongType }),
        ) { entry ->
            val comicId = entry.arguments?.getLong("comicId") ?: return@composable
            val vm: ReaderViewModel = viewModel(
                key = "reader-$comicId",
                factory = ReaderViewModel.factory(app, comicId),
            )
            ReaderScreen(viewModel = vm, onBack = { navController.popBackStack() })
        }
    }
}
