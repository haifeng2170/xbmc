/*
 *  Copyright (C) 2010-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/ios-common/AnnounceReceiver.h"

#include "Application.h"
#include "FileItem.h"
#include "PlayListPlayer.h"
#include "ServiceBroker.h"
#include "TextureCache.h"
#include "filesystem/SpecialProtocol.h"
#include "music/MusicDatabase.h"
#include "music/tags/MusicInfoTag.h"
#include "playlists/PlayList.h"
#include "utils/Variant.h"

#import "platform/darwin/ios/XBMCController.h"

#import <UIKit/UIKit.h>

id objectFromVariant(const CVariant& data);

NSArray* arrayFromVariantArray(const CVariant& data)
{
  if (!data.isArray())
    return nil;
  NSMutableArray* array = [[NSMutableArray alloc] initWithCapacity:data.size()];
  for (CVariant::const_iterator_array itr = data.begin_array(); itr != data.end_array(); ++itr)
    [array addObject:objectFromVariant(*itr)];

  return array;
}

NSDictionary* dictionaryFromVariantMap(const CVariant& data)
{
  if (!data.isObject())
    return nil;
  NSMutableDictionary* dict = [[NSMutableDictionary alloc] initWithCapacity:data.size()];
  for (CVariant::const_iterator_map itr = data.begin_map(); itr != data.end_map(); ++itr)
    [dict setValue:objectFromVariant(itr->second) forKey:@(itr->first.c_str())];

  return dict;
}

id objectFromVariant(const CVariant& data)
{
  if (data.isNull())
    return nil;
  if (data.isString())
    return @(data.asString().c_str());
  if (data.isWideString())
    return [NSString stringWithCString:(const char*)data.asWideString().c_str() encoding:NSUnicodeStringEncoding];
  if (data.isInteger())
    return @(data.asInteger());
  if (data.isUnsignedInteger())
    return @(data.asUnsignedInteger());
  if (data.isBoolean())
    return @(data.asBoolean() ? 1 : 0);
  if (data.isDouble())
    return @(data.asDouble());
  if (data.isArray())
    return arrayFromVariantArray(data);
  if (data.isObject())
    return dictionaryFromVariantMap(data);

  return nil;
}

void AnnounceBridge(ANNOUNCEMENT::AnnouncementFlag flag,
                    const char* sender,
                    const char* message,
                    const CVariant& data)
{
  int item_id = -1;
  std::string item_type = "";
  CVariant nonConstData = data;
  const std::string msg(message);

  // handle data which only has a database id and not the metadata inside
  if (msg == "OnPlay" || msg == "OnResume")
  {
    if (!nonConstData["item"].isNull())
    {
      if (!nonConstData["item"]["id"].isNull())
      {
        item_id = static_cast<int>(nonConstData["item"]["id"].asInteger());
      }

      if (!nonConstData["item"]["type"].isNull())
      {
        item_type = nonConstData["item"]["type"].asString();
      }
    }

    // if we got an id from the passed data
    // we need to get title, track, album and artist from the db
    if (item_id >= 0)
    {
      if (item_type == MediaTypeSong)
      {
        CMusicDatabase db;
        if (db.Open())
        {
          CSong song;
          if (db.GetSong(item_id, song))
          {
            nonConstData["item"]["title"] = song.strTitle;
            nonConstData["item"]["track"] = song.iTrack;
            nonConstData["item"]["album"] = song.strAlbum;
            nonConstData["item"]["artist"] = song.GetArtist();
          }
        }
      }
    }
  }

  //LOG(@"AnnounceBridge: [%s], [%s], [%s]", ANNOUNCEMENT::AnnouncementFlagToString(flag), sender, message);
  NSDictionary* dict = dictionaryFromVariantMap(nonConstData);
  //LOG(@"data: %@", dict.description);
  if (msg == "OnPlay" || msg == "OnResume")
  {
    NSDictionary* item = [dict valueForKey:@"item"];
    NSDictionary* player = [dict valueForKey:@"player"];
    [item setValue:[player valueForKey:@"speed"] forKey:@"speed"];
    std::string thumb = g_application.CurrentFileItem().GetArt("thumb");
    if (!thumb.empty())
    {
      bool needsRecaching;
      std::string cachedThumb(CTextureCache::GetInstance().CheckCachedImage(thumb, needsRecaching));
      //LOG("thumb: %s, %s", thumb.c_str(), cachedThumb.c_str());
      if (!cachedThumb.empty())
      {
        std::string thumbRealPath = CSpecialProtocol::TranslatePath(cachedThumb);
        [item setValue:@(thumbRealPath.c_str()) forKey:@"thumb"];
      }
    }
    double duration = g_application.GetTotalTime();
    if (duration > 0)
      [item setValue:@(duration) forKey:@"duration"];
    [item setValue:@(g_application.GetTime()) forKey:@"elapsed"];
    int current = CServiceBroker::GetPlaylistPlayer().GetCurrentSong();
    if (current >= 0)
    {
      [item setValue:@(current) forKey:@"current"];
      [item setValue:@(CServiceBroker::GetPlaylistPlayer()
                        .GetPlaylist(CServiceBroker::GetPlaylistPlayer().GetCurrentPlaylist()).size()
              forKey:@"total"];
    }
    if (g_application.CurrentFileItem().HasMusicInfoTag())
    {
      const std::vector<std::string>& genre =
          g_application.CurrentFileItem().GetMusicInfoTag()->GetGenre();
      if (!genre.empty())
      {
        NSMutableArray* genreArray = [[NSMutableArray alloc] initWithCapacity:genre.size()];
        for (std::vector<std::string>::const_iterator it = genre.begin(); it != genre.end(); ++it)
        {
          [genreArray addObject:@(it->c_str())];
        }
        [item setValue:genreArray forKey:@"genre"];
      }
    }
    //LOG(@"item: %@", item.description);
    [g_xbmcController performSelectorOnMainThread:@selector(onPlay:)
                                       withObject:item
                                    waitUntilDone:NO];
  }
  else if (msg == "OnSpeedChanged" || msg == "OnPause")
  {
    NSDictionary* item = [dict valueForKey:@"item"];
    NSDictionary* player = [dict valueForKey:@"player"];
    [item setValue:[player valueForKey:@"speed"] forKey:@"speed"];
    [item setValue:@(g_application.GetTime()) forKey:@"elapsed"];
    //LOG(@"item: %@", item.description);
    [g_xbmcController performSelectorOnMainThread:@selector(OnSpeedChanged:)
                                       withObject:item
                                    waitUntilDone:NO];
    if (msg == "OnPause")
      [g_xbmcController performSelectorOnMainThread:@selector(onPause:)
                                         withObject:[dict valueForKey:@"item"]
                                      waitUntilDone:NO];
  }
  else if (msg == "OnStop")
  {
    [g_xbmcController performSelectorOnMainThread:@selector(onStop:)
                                       withObject:[dict valueForKey:@"item"]
                                    waitUntilDone:NO];
  }
}

CAnnounceReceiver* CAnnounceReceiver::GetInstance()
{
  static CAnnounceReceiver announceReceiverInstance;
  return &announceReceiverInstance;
}

void CAnnounceReceiver::Initialize()
{
  CServiceBroker::GetAnnouncementManager()->AddAnnouncer(GetInstance());
}

void CAnnounceReceiver::DeInitialize()
{
  CServiceBroker::GetAnnouncementManager()->RemoveAnnouncer(GetInstance());
}

void CAnnounceReceiver::Announce(ANNOUNCEMENT::AnnouncementFlag flag,
                                 const char* sender,
                                 const char* message,
                                 const CVariant& data)
{
  // can be called from c++, we need an auto poll here.
  @autoreleasepool
  {
    AnnounceBridge(flag, sender, message, data);
  }
}
