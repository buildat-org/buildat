// [FS_TMP_SHARED] Two processes write the same file (the same content,
// as two clients a cache's same hash) over and over, each reading it back
// after its own write: never empty or short. fs_race_check.sh builds and
// runs it.
#include "interface/fs.h"
#include <fstream>
#include <iterator>
#include <cstdio>
#include <unistd.h>
#include <sys/wait.h>

static int run(const std::string &path, const std::string &data, int n)
{
	int bad = 0;
	for(int i = 0; i < n; i++){
		if(!interface::fs::write_file(path, data))
			continue;
		std::ifstream f(path, std::ios::binary);
		const std::string got((std::istreambuf_iterator<char>(f)),
				std::istreambuf_iterator<char>());
		if(got != data)
			bad++;
	}
	return bad;
}

int main(int argc, char **argv)
{
	if(argc < 2){
		fprintf(stderr, "usage: fs_race <dir>\n");
		return 2;
	}
	const std::string path = std::string(argv[1])+"/shared.bin";
	std::string data(256 * 1024, 'x');
	for(size_t i = 0; i < data.size(); i++)
		data[i] = (char)(i * 7919 % 251);
	const int N = 400, KIDS = 4;
	pid_t kids[KIDS];
	for(int k = 0; k < KIDS; k++){
		kids[k] = fork();
		if(kids[k] == 0)
			_exit(run(path, data, N) > 0 ? 1 : 0);
	}
	int failed = 0;
	for(int k = 0; k < KIDS; k++){
		int st = 0;
		waitpid(kids[k], &st, 0);
		if(!WIFEXITED(st) || WEXITSTATUS(st) != 0)
			failed++;
	}
	printf("fs_race: %d of %d writers read back a file not whole\n", failed,
			KIDS);
	return failed ? 1 : 0;
}
